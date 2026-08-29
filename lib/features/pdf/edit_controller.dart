import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../core/api/api_exception.dart';
import '../../core/files/picked_file.dart';
import '../../core/ui/request_state.dart';
import '../auth/session_controller.dart';
import 'pdf_repository.dart';
import 'pdf_tool.dart';

/// Drives one tool screen: pick files, run the edit, expose the four states.
class EditController extends ChangeNotifier {
  EditController({
    required this.tool,
    required PdfRepository repository,
    required SessionController session,
  })  : _repository = repository,
        _session = session;

  final PdfTool tool;
  final PdfRepository _repository;
  final SessionController _session;

  final List<PickedFile> _files = [];
  RequestState<EditedFile> _state = const RequestState<EditedFile>.idle();
  double _uploadProgress = 0;

  List<PickedFile> get files => List.unmodifiable(_files);
  RequestState<EditedFile> get state => _state;
  double get uploadProgress => _uploadProgress;
  bool get canRun => _files.length >= tool.minimumFiles && !_state.isLoading;

  Future<void> pickFiles() async {
    // file_picker 12 splits single and multiple selection into two calls.
    final selection = tool.allowsMultiple
        ? await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['pdf'],
          )
        : [
            ?await FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: const ['pdf'],
            ),
          ];
    if (selection.isEmpty) return; // the user backed out

    final picked = <PickedFile>[];
    for (final file in selection) {
      picked.add(await PickedFile.fromPlatformFile(file));
    }

    if (tool.allowsMultiple) {
      _files.addAll(picked);
    } else {
      _files
        ..clear()
        ..addAll(picked.take(1));
    }
    _state = const RequestState<EditedFile>.idle();
    notifyListeners();
  }

  void removeFile(int index) {
    _files.removeAt(index);
    notifyListeners();
  }

  void reorderFile(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    _files.insert(newIndex, _files.removeAt(oldIndex));
    notifyListeners();
  }

  void reset() {
    _files.clear();
    _state = const RequestState<EditedFile>.idle();
    _uploadProgress = 0;
    notifyListeners();
  }

  /// Runs the tool. [options] carries the per-tool form fields.
  Future<void> run(EditOptions options) async {
    if (!canRun) return;

    _state = const RequestState<EditedFile>.loading();
    _uploadProgress = 0;
    notifyListeners();

    try {
      final result = await switch (tool) {
        PdfTool.compress => _repository.compress(
            _files.first,
            imageQuality: options.imageQuality,
            onProgress: _reportProgress,
          ),
        PdfTool.merge => _repository.merge(_files, onProgress: _reportProgress),
        PdfTool.split => _repository.split(
            _files.first,
            pageRanges: options.pageRanges!,
            onProgress: _reportProgress,
          ),
        PdfTool.addText => _repository.addText(
            _files.first,
            text: options.text!,
            page: options.page!,
            x: options.x!,
            y: options.y!,
            fontSize: options.fontSize,
            color: options.color,
            onProgress: _reportProgress,
          ),
      };

      _session.applyQuotaAfterEdit(result.quotaRemaining);
      _state = RequestState<EditedFile>.success(result);
    } on ApiException catch (error) {
      // Quota failures land in QuotaExceeded, not Failure — see RequestState.
      _state = RequestState<EditedFile>.failed(error);
    }
    notifyListeners();
  }

  void _reportProgress(int sent, int total) {
    if (total <= 0) return;
    _uploadProgress = sent / total;
    notifyListeners();
  }
}

/// Per-tool form fields, collected by the tool screen.
class EditOptions {
  const EditOptions({
    this.imageQuality,
    this.pageRanges,
    this.text,
    this.page,
    this.x,
    this.y,
    this.fontSize = 12,
    this.color = '#000000',
  });

  final int? imageQuality;
  final String? pageRanges;
  final String? text;
  final int? page;
  final double? x;
  final double? y;
  final double fontSize;
  final String color;
}
