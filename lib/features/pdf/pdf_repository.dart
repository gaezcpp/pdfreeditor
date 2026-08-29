import 'package:dio/dio.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/config.dart';
import '../../core/files/file_saver.dart';
import '../../core/files/picked_file.dart';
import '../../core/files/save_destination.dart';
import '../../core/files/saved_file.dart';
import 'pdf_tool.dart';

/// The file the backend produced, once it has been handed to the platform.
class EditedFile {
  const EditedFile({required this.file, required this.quotaRemaining});

  final SavedFile file;

  /// From the `X-Quota-Remaining` header; null for premium users.
  final int? quotaRemaining;

  String get name => file.name;
}

/// Uploads to `/pdf/*` and saves what comes back to the device.
///
/// No PDF is manipulated here — that is the backend's job. This layer only
/// validates cheaply, uploads, and writes the result to local storage.
class PdfRepository {
  PdfRepository(this._client, this._destination);

  final ApiClient _client;
  final SaveDestinationStore _destination;

  Future<EditedFile> compress(
    PickedFile file, {
    int? imageQuality,
    ProgressCallback? onProgress,
  }) =>
      _run(
        PdfTool.compress,
        files: [file],
        fields: {'image_quality': ?imageQuality},
        onProgress: onProgress,
      );

  Future<EditedFile> merge(
    List<PickedFile> files, {
    ProgressCallback? onProgress,
  }) =>
      _run(PdfTool.merge, files: files, fieldName: 'files', onProgress: onProgress);

  Future<EditedFile> split(
    PickedFile file, {
    required String pageRanges,
    ProgressCallback? onProgress,
  }) =>
      _run(
        PdfTool.split,
        files: [file],
        fields: {'page_ranges': pageRanges},
        onProgress: onProgress,
      );

  Future<EditedFile> addText(
    PickedFile file, {
    required String text,
    required int page,
    required double x,
    required double y,
    double fontSize = 12,
    String color = '#000000',
    ProgressCallback? onProgress,
  }) =>
      _run(
        PdfTool.addText,
        files: [file],
        fields: {
          'text': text,
          'page': page,
          'x': x,
          'y': y,
          'font_size': fontSize,
          'color': color,
        },
        onProgress: onProgress,
      );

  Future<EditedFile> _run(
    PdfTool tool, {
    required List<PickedFile> files,
    Map<String, dynamic> fields = const {},
    String fieldName = 'file',
    ProgressCallback? onProgress,
  }) async {
    _assertWithinSizeLimit(files);
    // Fail fast instead of making the user wait out a connect timeout.
    await _client.requireConnection();

    final form = FormData();
    fields.forEach((key, value) => form.fields.add(MapEntry(key, '$value')));
    for (final file in files) {
      form.files.add(MapEntry(fieldName, await file.toMultipart()));
    }

    try {
      final response = await _client.dio.post<List<int>>(
        tool.endpoint,
        data: form,
        onSendProgress: onProgress,
        options: Options(responseType: ResponseType.bytes),
      );

      final saved = await saveDocument(
        bytes: response.data!,
        filename: _filenameFrom(response.headers) ?? 'edited.pdf',
        mimeType: tool == PdfTool.split
            ? 'application/zip'
            : 'application/pdf',
        destination: _destination.value,
      );
      return EditedFile(
        file: saved,
        quotaRemaining: int.tryParse(
          response.headers.value('x-quota-remaining') ?? '',
        ),
      );
    } on DioException catch (error) {
      throw error.asApiException;
    }
  }

  /// The backend enforces this too; checking here saves the user the upload.
  void _assertWithinSizeLimit(List<PickedFile> files) {
    for (final file in files) {
      if (file.sizeBytes > AppConfig.maxUploadBytes) {
        final limitMb = AppConfig.maxUploadBytes ~/ (1024 * 1024);
        throw FileTooLargeException(
          '"${file.name}" is ${file.readableSize}; the limit is $limitMb MB.',
        );
      }
    }
  }

  /// Reads the download name the server chose out of `Content-Disposition`.
  String? _filenameFrom(Headers headers) {
    final disposition = headers.value('content-disposition');
    if (disposition == null) return null;

    // RFC 5987 form wins when present: filename*=utf-8''doc%20final.pdf
    final encoded = RegExp(r"filename\*=(?:utf-8|UTF-8)''([^;]+)")
        .firstMatch(disposition)
        ?.group(1);
    if (encoded != null) return Uri.decodeComponent(encoded).trim();

    return RegExp(r'filename="?([^";]+)"?')
        .firstMatch(disposition)
        ?.group(1)
        ?.trim();
  }
}
