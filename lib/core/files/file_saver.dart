import 'save_destination.dart';
import 'saved_file.dart';
import 'file_saver_io.dart' if (dart.library.js_interop) 'file_saver_web.dart'
    as impl;

/// Writes a finished document somewhere the user can get at it.
///
/// The platforms have nothing in common here. Native builds can write to a
/// filesystem; a browser page cannot touch one at all and must hand the bytes
/// to the browser's download machinery. Conditional import keeps `dart:io` out
/// of the web build entirely — importing it there compiles, then throws.
///
/// [destination] only means something on native platforms; the web has exactly
/// one way to deliver a file and ignores it.
Future<SavedFile> saveDocument({
  required List<int> bytes,
  required String filename,
  String mimeType = 'application/pdf',
  SaveDestination destination = SaveDestination.ask,
}) =>
    impl.saveDocument(
      bytes: bytes,
      filename: filename,
      mimeType: mimeType,
      destination: destination,
    );
