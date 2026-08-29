import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'save_destination.dart';
import 'saved_file.dart';

/// Hands the bytes to the browser as a download.
///
/// A web page has no filesystem access, so there is no path to report back —
/// the file goes wherever the browser is configured to put downloads.
Future<SavedFile> saveDocument({
  required List<int> bytes,
  required String filename,
  String mimeType = 'application/pdf',
  // A browser has one delivery mechanism and no filesystem, so there is
  // nothing for this to choose between.
  SaveDestination destination = SaveDestination.ask,
}) async {
  final data = Uint8List.fromList(bytes).toJS;
  final blob = web.Blob([data].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);

  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  anchor.click();

  // Revoking immediately would race the download in some browsers.
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => web.URL.revokeObjectURL(url),
  );

  return SavedFile(name: filename, location: 'your Downloads folder');
}
