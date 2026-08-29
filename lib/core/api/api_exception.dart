import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'server_address.dart';

/// Typed counterparts to the backend's `{"error": {"code", "message", "details"}}`
/// envelope.
///
/// The UI branches on the exception type, never on the message text — messages
/// are for humans and may change; codes are the contract.
sealed class ApiException implements Exception {
  const ApiException(this.code, this.message, [this.details = const {}]);

  final String code;
  final String message;
  final Map<String, dynamic> details;

  @override
  String toString() => '$runtimeType($code): $message';

  /// Builds the right subtype from a Dio failure.
  factory ApiException.from(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const NetworkException(
          'The connection timed out. Check your network and try again.',
        );
      case DioExceptionType.transformTimeout:
        return const NetworkException(
          'The response took too long to read. Try again.',
        );
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        // In debug, name the address. "Check your connection" is useless advice
        // when the real cause is a backend that was never started, which is the
        // overwhelmingly common case while developing.
        return NetworkException(
          kDebugMode
              ? 'Could not reach the backend at ${ServerAddress.activeUrl}. '
                  'Is it running?'
              : 'Could not reach the server. Check your connection and try '
                  'again.',
        );
      case DioExceptionType.cancel:
        return const CancelledException();
      case DioExceptionType.badCertificate:
        return const NetworkException('The server certificate was rejected.');
      case DioExceptionType.badResponse:
        break;
    }

    final response = error.response;
    final status = response?.statusCode ?? 0;
    final envelope = _envelopeOf(response?.data);
    final code = envelope?['code'] as String? ?? 'unknown';
    final message =
        envelope?['message'] as String? ?? 'Something went wrong ($status).';
    final details = (envelope?['details'] as Map?)?.cast<String, dynamic>() ?? const {};

    return switch (code) {
      'quota_exceeded' => QuotaExceededException(message, details),
      'unauthenticated' => UnauthenticatedException(message),
      'conflict' => ConflictException(message),
      'file_too_large' => FileTooLargeException(message, details),
      'invalid_pdf' || 'pdf_processing_failed' => InvalidPdfException(message),
      'validation_error' => ValidationException(message, details),
      _ when status >= 500 => ServerException(message),
      _ => UnknownApiException(code, message, details),
    };
  }

  /// The error body can arrive as a decoded map or, for binary endpoints that
  /// fail, as raw bytes Dio never parsed.
  ///
  /// Every `/pdf/*` call asks for [ResponseType.bytes] so the edited file can
  /// be written to disk — which means their *error* bodies arrive as bytes too.
  /// Without decoding them here, a `quota_exceeded` response degrades to a
  /// generic failure and the paywall never opens.
  static Map<String, dynamic>? _envelopeOf(Object? data) {
    var decoded = data;

    if (decoded is List<int>) {
      decoded = _tryDecodeJson(utf8.decode(decoded, allowMalformed: true));
    } else if (decoded is String) {
      decoded = _tryDecodeJson(decoded);
    }

    if (decoded is Map && decoded['error'] is Map) {
      return (decoded['error'] as Map).cast<String, dynamic>();
    }
    return null;
  }

  static Object? _tryDecodeJson(String raw) {
    if (raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null; // not JSON — fall back to the status-code message
    }
  }
}

extension DioExceptionMapping on DioException {
  /// The typed error, reusing the one the interceptor already built if present.
  ApiException get asApiException =>
      error is ApiException ? error as ApiException : ApiException.from(this);
}

/// Free quota is spent for the week — the trigger for the paywall.
final class QuotaExceededException extends ApiException {
  const QuotaExceededException(String message, [Map<String, dynamic> details = const {}])
      : super('quota_exceeded', message, details);

  /// When the weekly window rolls over, if the server said.
  DateTime? get resetsAt {
    final raw = details['resets_at'];
    return raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
  }

  int? get limit => details['limit'] as int?;
}

/// The token is missing, expired, or was rejected after a refresh attempt.
final class UnauthenticatedException extends ApiException {
  const UnauthenticatedException(String message)
      : super('unauthenticated', message);
}

final class ConflictException extends ApiException {
  const ConflictException(String message) : super('conflict', message);
}

final class FileTooLargeException extends ApiException {
  const FileTooLargeException(String message, [Map<String, dynamic> details = const {}])
      : super('file_too_large', message, details);

  int? get maxBytes => details['max_bytes'] as int?;
}

final class InvalidPdfException extends ApiException {
  const InvalidPdfException(String message) : super('invalid_pdf', message);
}

final class ValidationException extends ApiException {
  const ValidationException(String message, [Map<String, dynamic> details = const {}])
      : super('validation_error', message, details);
}

/// No usable connection, a timeout, or the server was unreachable.
final class NetworkException extends ApiException {
  const NetworkException(String message) : super('network_error', message);
}

final class ServerException extends ApiException {
  const ServerException(String message) : super('server_error', message);
}

final class CancelledException extends ApiException {
  const CancelledException() : super('cancelled', 'The request was cancelled.');
}

final class UnknownApiException extends ApiException {
  const UnknownApiException(super.code, super.message, [super.details]);
}
