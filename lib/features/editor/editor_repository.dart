import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/config.dart';
import '../../core/files/file_saver.dart';
import '../../core/files/saved_file.dart';
import '../../core/files/picked_file.dart';
import '../../core/files/save_destination.dart';
import 'editor_models.dart';

/// Talks to `/editor/*`.
///
/// Every mutating call returns the whole document model rather than a patch:
/// one edit can move several objects (a redrawn neighbour, a removed image), so
/// the server's view is the only one worth trusting.
class EditorRepository {
  EditorRepository(this._client, this._destination);

  final ApiClient _client;
  final SaveDestinationStore _destination;

  Future<EditorDocument> open(PickedFile file, {ProgressCallback? onProgress}) async {
    if (file.sizeBytes > AppConfig.maxUploadBytes) {
      final limitMb = AppConfig.maxUploadBytes ~/ (1024 * 1024);
      throw FileTooLargeException(
        '"${file.name}" is ${file.readableSize}; the limit is $limitMb MB.',
      );
    }
    await _client.requireConnection();

    final form = FormData()
      ..files.add(MapEntry('file', await file.toMultipart()));

    return _document(
      () => _client.dio.post<Map<String, dynamic>>(
        '/editor/sessions',
        data: form,
        onSendProgress: onProgress,
      ),
    );
  }

  Future<EditorDocument> reload(String sessionId) => _document(
        () => _client.dio.get<Map<String, dynamic>>('/editor/sessions/$sessionId'),
      );

  /// The page as a PNG, with pending edits applied.
  Future<Uint8List> renderPage(
    String sessionId,
    int pageNumber, {
    int dpi = 130,
  }) async {
    try {
      final response = await _client.dio.get<List<int>>(
        '/editor/sessions/$sessionId/pages/$pageNumber',
        queryParameters: {'dpi': dpi},
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data!);
    } on DioException catch (error) {
      throw error.asApiException;
    }
  }

  Future<EditorDocument> replaceText(
    String sessionId, {
    required int page,
    required int span,
    required String text,
  }) =>
      _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/text',
          data: {'page': page, 'span': span, 'text': text},
        ),
      );

  Future<EditorDocument> deleteText(
    String sessionId, {
    required int page,
    required int index,
  }) =>
      _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/text/delete',
          data: {'page': page, 'index': index},
        ),
      );

  Future<EditorDocument> addText(
    String sessionId, {
    required int page,
    required String text,
    required double x,
    required double y,
    double size = 12,
    String color = '#000000',
  }) =>
      _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/text/add',
          data: {
            'page': page,
            'text': text,
            'x': x,
            'y': y,
            'size': size,
            'color': color,
          },
        ),
      );

  Future<EditorDocument> deleteImage(
    String sessionId, {
    required int page,
    required int index,
  }) =>
      _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/images/delete',
          data: {'page': page, 'index': index},
        ),
      );

  Future<EditorDocument> replaceImage(
    String sessionId, {
    required int page,
    required int index,
    required PickedFile image,
  }) async {
    await _client.requireConnection();
    final form = FormData()
      ..files.add(MapEntry('file', await image.toMultipart()));

    return _document(
      () => _client.dio.post<Map<String, dynamic>>(
        '/editor/sessions/$sessionId/images/replace',
        queryParameters: {'page': page, 'index': index},
        data: form,
      ),
    );
  }

  Future<EditorDocument> moveText(
    String sessionId, {
    required int page,
    required int index,
    required double dx,
    required double dy,
  }) =>
      _move(sessionId, '/text/move', page: page, index: index, dx: dx, dy: dy);

  Future<EditorDocument> moveImage(
    String sessionId, {
    required int page,
    required int index,
    required double dx,
    required double dy,
  }) =>
      _move(sessionId, '/images/move', page: page, index: index, dx: dx, dy: dy);

  Future<EditorDocument> styleText(
    String sessionId, {
    required int page,
    required int index,
    double? size,
    String? color,
  }) =>
      _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/text/style',
          data: {
            'page': page,
            'index': index,
            'size': ?size,
            'color': ?color,
          },
        ),
      );

  Future<EditorDocument> scaleImage(
    String sessionId, {
    required int page,
    required int index,
    required double scale,
  }) =>
      _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/images/scale',
          data: {'page': page, 'index': index, 'scale': scale},
        ),
      );

  Future<EditorDocument> addImage(
    String sessionId, {
    required int page,
    required double x,
    required double y,
    required PickedFile image,
    double? width,
  }) async {
    await _client.requireConnection();
    final form = FormData()
      ..files.add(MapEntry('file', await image.toMultipart()));

    return _document(
      () => _client.dio.post<Map<String, dynamic>>(
        '/editor/sessions/$sessionId/images/add',
        queryParameters: {
          'page': page,
          'x': x,
          'y': y,
          'width': ?width,
        },
        data: form,
      ),
    );
  }

  /// Drags are sent as deltas, not destinations.
  ///
  /// A delta replays correctly on top of earlier moves; an absolute position
  /// captured against a stale layout would snap the object back.
  Future<EditorDocument> _move(
    String sessionId,
    String path, {
    required int page,
    required int index,
    required double dx,
    required double dy,
  }) =>
      _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId$path',
          data: {'page': page, 'index': index, 'dx': dx, 'dy': dy},
        ),
      );

  Future<EditorDocument> undo(String sessionId) => _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/undo',
        ),
      );

  Future<EditorDocument> reset(String sessionId) => _document(
        () => _client.dio.post<Map<String, dynamic>>(
          '/editor/sessions/$sessionId/reset',
        ),
      );

  /// Charges one edit, downloads the result, and ends the session.
  Future<SavedResult> save(String sessionId, {required String filename}) async {
    await _client.requireConnection();
    try {
      final response = await _client.dio.post<List<int>>(
        '/editor/sessions/$sessionId/save',
        options: Options(responseType: ResponseType.bytes),
      );

      final saved = await saveDocument(
        bytes: response.data!,
        filename: _filenameFrom(response.headers) ?? filename,
        destination: _destination.value,
      );
      return SavedResult(
        file: saved,
        quotaRemaining: int.tryParse(
          response.headers.value('x-quota-remaining') ?? '',
        ),
      );
    } on DioException catch (error) {
      throw error.asApiException;
    }
  }

  /// Throws the session away. Failures are swallowed: the user has already
  /// moved on, and the server expires abandoned sessions anyway.
  Future<void> discard(String sessionId) async {
    try {
      await _client.dio.delete<void>('/editor/sessions/$sessionId');
    } on DioException {
      // Intentionally ignored.
    }
  }

  Future<EditorDocument> _document(
    Future<Response<Map<String, dynamic>>> Function() request,
  ) async {
    try {
      final response = await request();
      return EditorDocument.fromJson(response.data!);
    } on DioException catch (error) {
      throw error.asApiException;
    }
  }

  String? _filenameFrom(Headers headers) {
    final disposition = headers.value('content-disposition');
    if (disposition == null) return null;
    return RegExp(r'filename="?([^";]+)"?')
        .firstMatch(disposition)
        ?.group(1)
        ?.trim();
  }
}

class SavedResult {
  const SavedResult({required this.file, required this.quotaRemaining});

  final SavedFile file;
  final int? quotaRemaining;
}
