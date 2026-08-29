import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/api/api_exception.dart';

/// The backend's error envelope is the contract between the two halves of this
/// project; these tests pin the mapping so a rename on either side is caught.
DioException _badResponse(int status, Map<String, dynamic> body) {
  final options = RequestOptions(path: '/pdf/compress');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<Map<String, dynamic>>(
      requestOptions: options,
      statusCode: status,
      data: body,
    ),
  );
}

void main() {
  group('ApiException.from', () {
    test('maps quota_exceeded and exposes the reset time', () {
      final error = ApiException.from(
        _badResponse(403, {
          'error': {
            'code': 'quota_exceeded',
            'message': 'You have used all your free edits for this week.',
            'details': {'limit': 5, 'resets_at': '2026-08-31T00:00:00+00:00'},
          },
        }),
      );

      expect(error, isA<QuotaExceededException>());
      final quota = error as QuotaExceededException;
      expect(quota.limit, 5);
      expect(quota.resetsAt, isNotNull);
      expect(quota.resetsAt!.toUtc(), DateTime.utc(2026, 8, 31));
    });

    test('maps file_too_large and carries the byte cap', () {
      final error = ApiException.from(
        _badResponse(413, {
          'error': {
            'code': 'file_too_large',
            'message': 'Too big.',
            'details': {'max_bytes': 26214400},
          },
        }),
      ) as FileTooLargeException;

      expect(error.maxBytes, 26214400);
    });

    test('folds pdf_processing_failed in with invalid_pdf', () {
      final error = ApiException.from(
        _badResponse(422, {
          'error': {'code': 'pdf_processing_failed', 'message': 'Nope.'},
        }),
      );

      expect(error, isA<InvalidPdfException>());
    });

    test('maps unauthenticated', () {
      final error = ApiException.from(
        _badResponse(401, {
          'error': {'code': 'unauthenticated', 'message': 'Invalid token.'},
        }),
      );

      expect(error, isA<UnauthenticatedException>());
    });

    test('treats an unrecognized 5xx as a server error', () {
      final error = ApiException.from(_badResponse(503, const {}));

      expect(error, isA<ServerException>());
    });

    test('keeps an unknown code rather than guessing', () {
      final error = ApiException.from(
        _badResponse(400, {
          'error': {'code': 'brand_new_code', 'message': 'Hello.'},
        }),
      );

      expect(error, isA<UnknownApiException>());
      expect(error.code, 'brand_new_code');
    });

    test('decodes an error body that arrived as raw bytes', () {
      // Every /pdf/* call requests ResponseType.bytes so the result can be
      // written to disk, so its error bodies arrive unparsed. Reading them is
      // what makes the paywall fire instead of a generic failure banner.
      final options = RequestOptions(path: '/pdf/compress');
      final error = ApiException.from(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response<List<int>>(
            requestOptions: options,
            statusCode: 403,
            data: utf8.encode(
              jsonEncode({
                'error': {
                  'code': 'quota_exceeded',
                  'message': 'Out of edits.',
                  'details': {'resets_at': '2026-08-31T00:00:00+00:00'},
                },
              }),
            ),
          ),
        ),
      );

      expect(error, isA<QuotaExceededException>());
      expect((error as QuotaExceededException).resetsAt, isNotNull);
    });

    test('falls back gracefully when the body is not JSON at all', () {
      final options = RequestOptions(path: '/pdf/compress');
      final error = ApiException.from(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response<List<int>>(
            requestOptions: options,
            statusCode: 502,
            data: utf8.encode('<html>Bad Gateway</html>'),
          ),
        ),
      );

      expect(error, isA<ServerException>());
    });

    test('reports connection failures as network errors, not server errors', () {
      final error = ApiException.from(
        DioException(
          requestOptions: RequestOptions(path: '/pdf/compress'),
          type: DioExceptionType.connectionError,
        ),
      );

      expect(error, isA<NetworkException>());
    });

    test('reports timeouts as network errors', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        final error = ApiException.from(
          DioException(
            requestOptions: RequestOptions(path: '/pdf/compress'),
            type: type,
          ),
        );
        expect(error, isA<NetworkException>(), reason: '$type');
      }
    });
  });
}
