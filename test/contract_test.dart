@Tags(['contract'])
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/api/api_exception.dart';
import 'package:pdfreeditor/features/user/user_status.dart';

/// Contract tests against a **running backend**.
///
/// The unit tests elsewhere feed hand-written JSON to the parsers, which only
/// proves the parsers are self-consistent. These run the real server, so a
/// renamed field or a dropped header fails here instead of on a device.
///
/// Start the backend first (see backend/README.md), then:
///   flutter test test/contract_test.dart
///
/// With no server reachable the whole group is skipped rather than failing —
/// a red suite should mean broken code, not a backend you did not boot.
const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

Dio _client() => Dio(
      BaseOptions(
        baseUrl: '$_baseUrl/api/v1',
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 60),
        validateStatus: (status) => status != null && status < 400,
      ),
    );

Future<bool> _serverIsUp() async {
  try {
    await Dio(BaseOptions(connectTimeout: const Duration(seconds: 2)))
        .get<dynamic>('$_baseUrl/health');
    return true;
  } on DioException {
    return false;
  }
}

void main() async {
  final up = await _serverIsUp();

  group(
    'backend contract',
    skip: up ? null : 'No backend reachable at $_baseUrl — skipped.',
    () {
      late Dio dio;
      late String accessToken;
      late List<int> samplePdf;

      setUpAll(() {
        samplePdf = File('test/fixtures/sample.pdf').readAsBytesSync();
      });

      setUp(() async {
        dio = _client();
        // A fresh account per test keeps the quota assertions independent.
        final email = 'contract-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final response = await dio.post<Map<String, dynamic>>(
          '/auth/register',
          data: {'email': email, 'password': 'contract-test-pw'},
        );
        accessToken = response.data!['access_token'] as String;
        dio.options.headers['Authorization'] = 'Bearer $accessToken';
      });

      test('register returns the token fields the client stores', () async {
        final response = await _client().post<Map<String, dynamic>>(
          '/auth/register',
          data: {
            'email': 'shape-${DateTime.now().microsecondsSinceEpoch}@example.com',
            'password': 'contract-test-pw',
          },
        );

        final body = response.data!;
        expect(body['access_token'], isA<String>());
        expect(body['refresh_token'], isA<String>());
        expect(body['expires_in'], isA<int>());
      });

      test('UserStatus parses the real status payload', () async {
        final response = await dio.get<Map<String, dynamic>>('/users/me/status');
        final status = UserStatus.fromJson(response.data!);

        expect(status.isPremium, isFalse);
        expect(status.quota.limit, greaterThan(0));
        expect(status.quota.used, 0);
        expect(status.quota.periodEnd.isAfter(status.quota.periodStart), isTrue);
      });

      test('compress returns a PDF, a filename, and the quota header', () async {
        final form = FormData()
          ..files.add(
            MapEntry(
              'file',
              MultipartFile.fromBytes(samplePdf, filename: 'sample.pdf'),
            ),
          );

        final response = await dio.post<List<int>>(
          '/pdf/compress',
          data: form,
          options: Options(responseType: ResponseType.bytes),
        );

        expect(response.headers.value('content-type'), contains('application/pdf'));
        expect(response.data!.take(5), equals('%PDF-'.codeUnits));

        // The two headers PdfRepository reads off the response.
        final disposition = response.headers.value('content-disposition');
        expect(disposition, contains('sample-compressed.pdf'));
        expect(int.tryParse(response.headers.value('x-quota-remaining') ?? ''),
            isNotNull);
      });

      test('split with several ranges comes back as a ZIP', () async {
        final form = FormData()
          ..fields.add(const MapEntry('page_ranges', '1,3'))
          ..files.add(
            MapEntry(
              'file',
              MultipartFile.fromBytes(samplePdf, filename: 'sample.pdf'),
            ),
          );

        final response = await dio.post<List<int>>(
          '/pdf/split',
          data: form,
          options: Options(responseType: ResponseType.bytes),
        );

        expect(response.headers.value('content-type'), contains('application/zip'));
      });

      test('a non-PDF upload maps to InvalidPdfException', () async {
        final form = FormData()
          ..files.add(
            MapEntry(
              'file',
              MultipartFile.fromBytes(
                'this is not a pdf'.codeUnits,
                filename: 'fake.pdf',
              ),
            ),
          );

        try {
          await dio.post<List<int>>('/pdf/compress', data: form);
          fail('Expected the server to reject a non-PDF.');
        } on DioException catch (error) {
          expect(ApiException.from(error), isA<InvalidPdfException>());
        }
      });

      test('exhausting the quota maps to QuotaExceededException', () async {
        final limit = UserStatus.fromJson(
          (await dio.get<Map<String, dynamic>>('/users/me/status')).data!,
        ).quota.limit!;

        Future<Response<List<int>>> compress() => dio.post<List<int>>(
              '/pdf/compress',
              data: FormData()
                ..files.add(
                  MapEntry(
                    'file',
                    MultipartFile.fromBytes(samplePdf, filename: 'sample.pdf'),
                  ),
                ),
              options: Options(responseType: ResponseType.bytes),
            );

        for (var i = 0; i < limit; i++) {
          await compress();
        }

        try {
          await compress();
          fail('Expected the quota to be exhausted after $limit edits.');
        } on DioException catch (error) {
          final mapped = ApiException.from(error);
          expect(mapped, isA<QuotaExceededException>());
          // The paywall needs this to tell the user when they can edit again.
          expect((mapped as QuotaExceededException).resetsAt, isNotNull);
        }
      });

      test('an unauthenticated call maps to UnauthenticatedException', () async {
        try {
          await _client().get<Map<String, dynamic>>('/users/me/status');
          fail('Expected a 401 without a token.');
        } on DioException catch (error) {
          expect(ApiException.from(error), isA<UnauthenticatedException>());
        }
      });
    },
  );
}
