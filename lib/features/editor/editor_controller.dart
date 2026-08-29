import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../core/api/api_exception.dart';
import '../../core/ui/request_state.dart';
import '../auth/session_controller.dart';
import '../../core/files/picked_file.dart';
import 'editor_models.dart';
import 'editor_repository.dart';

/// What a tap on the page will place next.
enum PlacementMode { none, text, image }

/// Drives the editor screen: which document, which page, what is selected.
///
/// Every mutation goes to the server and the returned document replaces the
/// local one. There is no optimistic local model, because a single edit can
/// change objects the client did not touch — an overlapping line gets redrawn,
/// a deleted image takes its box away — and guessing at that would drift.
class EditorController extends ChangeNotifier {
  EditorController({
    required EditorRepository repository,
    required SessionController session,
  })  : _repository = repository,
        _session = session;

  final EditorRepository _repository;
  final SessionController _session;

  EditorDocument? _document;
  int _pageNumber = 1;
  Uint8List? _pageImage;
  int? _renderedRevision;

  RequestState<EditorDocument> _state = const RequestState<EditorDocument>.idle();
  RequestState<SavedResult> _saveState = const RequestState<SavedResult>.idle();
  Object? _selection; // EditorSpan or EditorImage
  PlacementMode _placement = PlacementMode.none;
  bool _busy = false;

  EditorDocument? get document => _document;
  EditorPage? get page => _document?.page(_pageNumber);
  int get pageNumber => _pageNumber;
  Uint8List? get pageImage => _pageImage;
  RequestState<EditorDocument> get state => _state;
  RequestState<SavedResult> get saveState => _saveState;
  Object? get selection => _selection;
  bool get isBusy => _busy;
  bool get isStale => _renderedRevision != _document?.revision;

  EditorSpan? get selectedSpan => _selection is EditorSpan ? _selection as EditorSpan : null;
  EditorImage? get selectedImage =>
      _selection is EditorImage ? _selection as EditorImage : null;

  /// Pick a PDF and open it for editing.
  Future<void> openDocument() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (picked == null) return;

    final file = await PickedFile.fromPlatformFile(picked);

    _state = const RequestState<EditorDocument>.loading();
    _saveState = const RequestState<SavedResult>.idle();
    notifyListeners();

    try {
      final document = await _repository.open(file);
      _document = document;
      _pageNumber = 1;
      _selection = null;
      _state = RequestState<EditorDocument>.success(document);
      notifyListeners();
      await _refreshRender();
    } on ApiException catch (error) {
      _state = RequestState<EditorDocument>.failed(error);
      notifyListeners();
    }
  }

  void select(Object? object) {
    _selection = object;
    notifyListeners();
  }

  /// What the next tap on empty canvas will do.
  ///
  /// Placing needs a point, and the only honest way to get one is to let the
  /// user pick it on the page rather than guessing a position for them.
  PlacementMode get placement => _placement;

  void startPlacing(PlacementMode mode) {
    _placement = mode;
    _selection = null;
    notifyListeners();
  }

  void cancelPlacing() {
    if (_placement == PlacementMode.none) return;
    _placement = PlacementMode.none;
    notifyListeners();
  }

  Future<void> goToPage(int number) async {
    final document = _document;
    if (document == null || number < 1 || number > document.pageCount) return;
    _pageNumber = number;
    _selection = null;
    notifyListeners();
    await _refreshRender();
  }

  Future<void> replaceText(EditorSpan span, String text) =>
      _mutate(() => _repository.replaceText(
            _document!.id,
            page: _pageNumber,
            span: span.index,
            text: text,
          ));

  Future<void> deleteSpan(EditorSpan span) => _mutate(
        () => _repository.deleteText(
          _document!.id,
          page: _pageNumber,
          index: span.index,
        ),
      );

  Future<void> deleteImage(EditorImage image) => _mutate(
        () => _repository.deleteImage(
          _document!.id,
          page: _pageNumber,
          index: image.index,
        ),
      );

  Future<void> replaceImage(EditorImage image) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (picked == null) return;
    final replacement = await PickedFile.fromPlatformFile(picked);

    await _mutate(
      () => _repository.replaceImage(
        _document!.id,
        page: _pageNumber,
        index: image.index,
        image: replacement,
      ),
    );
  }

  Future<void> addText({
    required String text,
    required double x,
    required double y,
    double size = 14,
    String color = '#000000',
  }) =>
      _mutate(() => _repository.addText(
            _document!.id,
            page: _pageNumber,
            text: text,
            x: x,
            y: y,
            size: size,
            color: color,
          ));

  /// Commit a drag. [dx]/[dy] are in PDF points, not screen pixels.
  Future<void> moveSpan(EditorSpan span, double dx, double dy) => _mutate(
        () => _repository.moveText(
          _document!.id,
          page: _pageNumber,
          index: span.index,
          dx: dx,
          dy: dy,
        ),
      );

  Future<void> moveImage(EditorImage image, double dx, double dy) => _mutate(
        () => _repository.moveImage(
          _document!.id,
          page: _pageNumber,
          index: image.index,
          dx: dx,
          dy: dy,
        ),
      );

  Future<void> setSpanStyle(EditorSpan span, {double? size, String? color}) =>
      _mutate(
        () => _repository.styleText(
          _document!.id,
          page: _pageNumber,
          index: span.index,
          size: size,
          color: color,
        ),
      );

  Future<void> scaleImage(EditorImage image, double scale) => _mutate(
        () => _repository.scaleImage(
          _document!.id,
          page: _pageNumber,
          index: image.index,
          scale: scale,
        ),
      );

  Future<void> addTextAt({
    required double x,
    required double y,
    required String text,
    double size = 14,
    String color = '#000000',
  }) =>
      _mutate(
        () => _repository.addText(
          _document!.id,
          page: _pageNumber,
          text: text,
          x: x,
          y: y,
          size: size,
          color: color,
        ),
      );

  /// Pick an image and drop it at the given point on the page.
  Future<void> addImageAt({required double x, required double y}) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (picked == null) return;
    final image = await PickedFile.fromPlatformFile(picked);

    await _mutate(
      () => _repository.addImage(
        _document!.id,
        page: _pageNumber,
        x: x,
        y: y,
        image: image,
      ),
    );
  }

  Future<void> undo() => _mutate(() => _repository.undo(_document!.id));

  Future<void> revertAll() => _mutate(() => _repository.reset(_document!.id));

  /// Charge one edit, download the result, and close the document.
  Future<void> save() async {
    final document = _document;
    if (document == null || _busy) return;

    _busy = true;
    _saveState = const RequestState<SavedResult>.loading();
    notifyListeners();

    try {
      final result = await _repository.save(document.id, filename: document.filename);
      _session.applyQuotaAfterEdit(result.quotaRemaining);
      _saveState = RequestState<SavedResult>.success(result);
      // The session is spent server-side; drop it here too so the UI cannot
      // offer edits that would now 409.
      _document = null;
      _pageImage = null;
      _selection = null;
      _state = const RequestState<EditorDocument>.idle();
    } on ApiException catch (error) {
      _saveState = RequestState<SavedResult>.failed(error);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> discard() async {
    final document = _document;
    _document = null;
    _pageImage = null;
    _selection = null;
    _state = const RequestState<EditorDocument>.idle();
    _saveState = const RequestState<SavedResult>.idle();
    notifyListeners();
    if (document != null) await _repository.discard(document.id);
  }

  Future<void> _mutate(Future<EditorDocument> Function() action) async {
    if (_document == null || _busy) return;

    _busy = true;
    notifyListeners();

    try {
      _document = await action();
      // Object handles survive edits now, but the selected *snapshot* is stale
      // once the server has recomputed positions and sizes.
      _selection = null;
      _placement = PlacementMode.none;
      _state = RequestState<EditorDocument>.success(_document!);
    } on ApiException catch (error) {
      _state = RequestState<EditorDocument>.failed(error);
    } finally {
      _busy = false;
      notifyListeners();
    }

    if (_state is Success<EditorDocument>) await _refreshRender();
  }

  Future<void> _refreshRender() async {
    final document = _document;
    if (document == null) return;

    try {
      final image = await _repository.renderPage(document.id, _pageNumber);
      // Guard against an out-of-order render landing after a newer edit.
      if (_document?.id != document.id) return;
      _pageImage = image;
      _renderedRevision = document.revision;
    } on ApiException {
      // Keep showing the previous frame; isStale tells the UI it is behind.
      _renderedRevision = -1;
    }
    notifyListeners();
  }
}
