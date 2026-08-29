import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/files/picked_file.dart';

/// These run in the browser too (`flutter test --platform chrome`), which is
/// the point: the bug they pin only ever appeared on web.
void main() {
  final bytes = Uint8List.fromList('%PDF-1.7 hello'.codeUnits);

  group('PickedFile.fromParts', () {
    test('a browser pick has no path, so it carries its bytes', () async {
      var reads = 0;

      final file = await PickedFile.fromParts(
        name: 'label.pdf',
        sizeBytes: bytes.length,
        path: null, // what file_picker gives you in Chrome and Safari
        readBytes: () async {
          reads++;
          return bytes;
        },
      );

      // The old code treated a null path as "unreadable" and refused to upload.
      expect(file, isA<PickedFileBytes>());
      expect((file as PickedFileBytes).bytes, bytes);
      expect(reads, 1);
    });

    test('a native pick keeps the path and never reads the file', () async {
      var reads = 0;

      final file = await PickedFile.fromParts(
        name: 'label.pdf',
        sizeBytes: 1024,
        path: '/storage/emulated/0/Download/label.pdf',
        readBytes: () async {
          reads++;
          return bytes;
        },
      );

      expect(file, isA<PickedFilePath>());
      expect(
        (file as PickedFilePath).path,
        '/storage/emulated/0/Download/label.pdf',
      );
      // Streaming from disk is the whole reason to prefer the path.
      expect(reads, 0, reason: 'a path-backed pick must not buffer the file');
    });

    test('both forms report the same name and size', () async {
      final web = await PickedFile.fromParts(
        name: 'a.pdf',
        sizeBytes: 2048,
        path: null,
        readBytes: () async => bytes,
      );
      final native = await PickedFile.fromParts(
        name: 'a.pdf',
        sizeBytes: 2048,
        path: '/tmp/a.pdf',
        readBytes: () async => bytes,
      );

      expect(web.name, native.name);
      expect(web.sizeBytes, native.sizeBytes);
    });
  });

  group('a byte-backed pick can still be uploaded', () {
    test('it builds a multipart part with the right filename', () async {
      final file = PickedFileBytes(
        name: 'label.pdf',
        sizeBytes: bytes.length,
        bytes: bytes,
      );

      final part = await file.toMultipart();

      expect(part.filename, 'label.pdf');
      expect(part.length, bytes.length);
    });
  });

  group('readableSize', () {
    test('uses KB below a megabyte', () {
      final file = PickedFileBytes(
        name: 'a.pdf',
        sizeBytes: 3 * 1024,
        bytes: bytes,
      );
      expect(file.readableSize, '3 KB');
    });

    test('uses MB at and above a megabyte', () {
      final file = PickedFileBytes(
        name: 'a.pdf',
        sizeBytes: (2.5 * 1024 * 1024).round(),
        bytes: bytes,
      );
      expect(file.readableSize, '2.5 MB');
    });
  });
}
