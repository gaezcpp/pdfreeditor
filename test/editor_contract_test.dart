@Tags(['contract'])
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/features/editor/editor_models.dart';

/// The editor flow against a **running backend**, using the real QR label.
///
/// This is the end the unit tests cannot reach: that the client's model parses
/// what the server actually sends, and that editing the number on a real label
/// does the right thing to the objects around it.
///
/// Skipped when no backend is reachable. See test/contract_test.dart.
const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

const labelNumber = '148100011059';
const neighbour = 'ASS1';

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
    'editor contract',
    skip: up ? null : 'No backend reachable at $_baseUrl — skipped.',
    () {
      late Dio dio;
      late List<int> label;

      setUpAll(() {
        label = File('test/fixtures/qr-label.pdf').readAsBytesSync();
      });

      setUp(() async {
        dio = _client();
        final email = 'editor-${DateTime.now().microsecondsSinceEpoch}@example.com';
        final registered = await dio.post<Map<String, dynamic>>(
          '/auth/register',
          data: {'email': email, 'password': 'contract-test-pw'},
        );
        dio.options.headers['Authorization'] =
            'Bearer ${registered.data!['access_token']}';
      });

      Future<EditorDocument> open() async {
        final form = FormData()
          ..files.add(
            MapEntry(
              'file',
              MultipartFile.fromBytes(label, filename: 'qr-label.pdf'),
            ),
          );
        final response = await dio.post<Map<String, dynamic>>(
          '/editor/sessions',
          data: form,
        );
        return EditorDocument.fromJson(response.data!);
      }

      Future<EditorDocument> post(String path, Object? data) async {
        final response =
            await dio.post<Map<String, dynamic>>(path, data: data);
        return EditorDocument.fromJson(response.data!);
      }

      test('the client model parses a real session payload', () async {
        final document = await open();

        expect(document.pageCount, 1);
        final page = document.pages.single;
        expect(page.spans.map((span) => span.text).first, labelNumber);
        expect(page.images, hasLength(1));

        // Geometry the overlay depends on.
        expect(page.width, greaterThan(0));
        expect(page.spans.first.bbox.width, greaterThan(0));
        expect(page.spans.first.substituteFont, 'hebo');
      });

      test('changing the label number leaves the rest of the label alone',
          () async {
        final document = await open();

        final updated = await post(
          '/editor/sessions/${document.id}/text',
          {'page': 1, 'span': 0, 'text': '148100011062'},
        );

        final texts = updated.pages.single.spans.map((span) => span.text);
        expect(texts, contains('148100011062'));
        expect(texts, isNot(contains(labelNumber)));
        // The line whose box overlaps the number must survive.
        expect(texts, contains(neighbour));
        expect(updated.pages.single.images, hasLength(1));
      });

      test('removing the QR keeps the printed number', () async {
        final document = await open();

        final updated = await post(
          '/editor/sessions/${document.id}/images/delete',
          {'page': 1, 'index': 0},
        );

        expect(updated.pages.single.images, isEmpty);
        expect(
          updated.pages.single.spans.map((span) => span.text),
          contains(labelNumber),
        );
      });

      test('the page renders as a PNG the editor can display', () async {
        final document = await open();

        final response = await dio.get<List<int>>(
          '/editor/sessions/${document.id}/pages/1',
          queryParameters: {'dpi': 90},
          options: Options(responseType: ResponseType.bytes),
        );

        expect(response.data!.take(4), equals([0x89, 0x50, 0x4E, 0x47]));
      });

      test('undo restores the previous text', () async {
        final document = await open();
        await post(
          '/editor/sessions/${document.id}/text',
          {'page': 1, 'span': 0, 'text': '999'},
        );

        final reverted = await post('/editor/sessions/${document.id}/undo', null);

        expect(
          reverted.pages.single.spans.map((span) => span.text),
          contains(labelNumber),
        );
        expect(reverted.hasEdits, isFalse);
      });

      test('the client model parses moved, resized and added objects', () async {
        final document = await open();

        final moved = await post(
          '/editor/sessions/${document.id}/text/move',
          {'page': 1, 'index': 0, 'dx': 30, 'dy': -20},
        );
        final before = document.pages.single.spans.first.bbox;
        final after = moved.pages.single.spans.first.bbox;
        expect(after.left, closeTo(before.left + 30, 3));

        final resized = await post(
          '/editor/sessions/${document.id}/text/style',
          {'page': 1, 'index': 0, 'size': 50},
        );
        expect(resized.pages.single.spans.first.size, 50);

        final added = await post(
          '/editor/sessions/${document.id}/text/add',
          {'page': 1, 'text': 'REVISI B', 'x': 60, 'y': 120, 'size': 26},
        );
        final placed =
            added.pages.single.spans.firstWhere((span) => span.added);
        expect(placed.text, 'REVISI B');
        // The handle the server assigned has to come back, or the client
        // cannot move what it just placed.
        expect(placed.index, greaterThanOrEqualTo(4));

        final scaled = await post(
          '/editor/sessions/${document.id}/images/scale',
          {'page': 1, 'index': 0, 'scale': 0.5},
        );
        final image = scaled.pages.single.images.single;
        expect(image.bbox.width, closeTo(485.76 * 0.5, 5));
      });

      test('many edits cost exactly one saved edit', () async {
        final document = await open();
        await post(
          '/editor/sessions/${document.id}/text',
          {'page': 1, 'span': 0, 'text': '148100011062'},
        );
        await post(
          '/editor/sessions/${document.id}/text',
          {'page': 1, 'span': 3, 'text': '781-1(31)'},
        );

        final before = await dio.get<Map<String, dynamic>>('/users/me/status');
        expect(before.data!['quota']['used'], 0); // previews are free

        final saved = await dio.post<List<int>>(
          '/editor/sessions/${document.id}/save',
          options: Options(responseType: ResponseType.bytes),
        );
        expect(saved.data!.take(5), equals('%PDF-'.codeUnits));

        final after = await dio.get<Map<String, dynamic>>('/users/me/status');
        expect(after.data!['quota']['used'], 1);
      });
    },
  );
}
