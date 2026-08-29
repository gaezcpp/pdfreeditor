import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'save_destination.dart';
import 'saved_file.dart';

/// Saves to a folder the user picks, or to the app's own documents directory.
///
/// On Android the app directory is *private* storage: nothing outside this app
/// can list or open it, so a file saved there is effectively invisible. That is
/// why [SaveDestination.ask] is the default — it goes through the system save
/// dialog, which needs no storage permission and puts the file where the person
/// chose.
Future<SavedFile> saveDocument({
  required List<int> bytes,
  required String filename,
  String mimeType = 'application/pdf',
  SaveDestination destination = SaveDestination.ask,
}) async {
  if (destination == SaveDestination.ask) {
    final saved = await _saveViaDialog(
      bytes: bytes,
      filename: filename,
      mimeType: mimeType,
    );
    // Cancelling must not lose the file: the edit has already been paid for
    // out of the weekly quota, so fall back to somewhere it survives.
    if (saved != null) return saved;
  }

  return _saveToAppFolder(bytes: bytes, filename: filename);
}

Future<SavedFile?> _saveViaDialog({
  required List<int> bytes,
  required String filename,
  required String mimeType,
}) async {
  final uri = await FilePicker.saveFile(
    fileName: filename,
    bytes: Uint8List.fromList(bytes),
    mimeType: mimeType,
    dialogTitle: 'Save $filename',
  );
  if (uri == null) return null; // the user backed out

  // A `file:` result has a real path to show. Android usually hands back a
  // `content:` URI instead, which names no filesystem location at all.
  if (uri.scheme == 'file') {
    final path = uri.toFilePath();
    return SavedFile(
      name: path.split(Platform.pathSeparator).last,
      location: path,
      path: path,
    );
  }
  return SavedFile(name: filename, location: 'the folder you chose');
}

Future<SavedFile> _saveToAppFolder({
  required List<int> bytes,
  required String filename,
}) async {
  final documents = await getApplicationDocumentsDirectory();
  final folder = Directory('${documents.path}/PDFree');
  await folder.create(recursive: true);

  final target = File(_uniquePath(folder, filename));
  await target.writeAsBytes(bytes, flush: true);

  return SavedFile(
    name: target.uri.pathSegments.last,
    location: target.path,
    path: target.path,
  );
}

/// Never overwrite an earlier result: "doc.pdf" becomes "doc (2).pdf".
String _uniquePath(Directory folder, String name) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';

  var candidate = '${folder.path}/$name';
  var counter = 2;
  while (File(candidate).existsSync()) {
    candidate = '${folder.path}/$stem ($counter)$extension';
    counter++;
  }
  return candidate;
}
