import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';

/// A file the user chose, in whatever form the platform can actually give it.
///
/// The two platforms hand back different things and neither can be faked into
/// the other: Android gives a real path that can be streamed from disk, while a
/// browser gives a blob with no path at all. Treating "no path" as a failure is
/// what made every upload fail in Chrome, so the difference is modelled here
/// instead of assumed away.
sealed class PickedFile {
  const PickedFile({required this.name, required this.sizeBytes});

  final String name;
  final int sizeBytes;

  /// The multipart part for this file, built the way its platform allows.
  Future<MultipartFile> toMultipart();

  String get readableSize {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / 1024).ceil()} KB';
  }

  /// Adapts a picker result. Prefers the path when there is one, so native
  /// builds stream from disk rather than holding the file in memory.
  static Future<PickedFile> fromPlatformFile(PlatformFile file) async =>
      fromParts(
        name: file.name,
        sizeBytes: await file.length(),
        path: file.path,
        readBytes: file.readAsBytes,
      );

  /// The platform-free seam, so the choice can be tested without a picker.
  ///
  /// `PlatformFile` is a `base` class and cannot be faked outside its own
  /// library, so this is the only point at which the path-versus-bytes decision
  /// can be exercised by a test.
  static Future<PickedFile> fromParts({
    required String name,
    required int sizeBytes,
    required String? path,
    required Future<Uint8List> Function() readBytes,
  }) async {
    if (path != null) {
      return PickedFilePath(name: name, sizeBytes: sizeBytes, path: path);
    }
    return PickedFileBytes(
      name: name,
      sizeBytes: sizeBytes,
      bytes: await readBytes(),
    );
  }
}

/// A file on disk: Android, and desktop if it is ever built.
final class PickedFilePath extends PickedFile {
  const PickedFilePath({
    required super.name,
    required super.sizeBytes,
    required this.path,
  });

  final String path;

  @override
  Future<MultipartFile> toMultipart() =>
      MultipartFile.fromFile(path, filename: name);
}

/// A file held in memory: the browser, where there is no path to stream from.
final class PickedFileBytes extends PickedFile {
  const PickedFileBytes({
    required super.name,
    required super.sizeBytes,
    required this.bytes,
  });

  final Uint8List bytes;

  @override
  Future<MultipartFile> toMultipart() async =>
      MultipartFile.fromBytes(bytes, filename: name);
}