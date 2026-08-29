import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../config.dart';
import 'api_exception.dart';
import 'server_address.dart';
import 'token_store.dart';

/// The single configured [Dio] every repository shares.
///
/// Responsibilities, in the order they matter:
///
/// * attach the bearer token, refreshing it *before* the request when it is
///   about to expire — a 401-then-retry cannot rescue a multipart upload,
///   because the file stream has already been consumed by the time the retry
///   would fire;
/// * fall back to a one-shot retry after a 401 for ordinary JSON calls;
/// * translate every failure into a typed [ApiException];
/// * refuse to start an upload with no usable connection.
class ApiClient {
  ApiClient({
    required TokenStore tokens,
    required ServerAddress address,
    Dio? dio,
    Connectivity? connectivity,
  })  : _tokens = tokens,
        _address = address,
        _connectivity = connectivity ?? Connectivity(),
        _dio = dio ?? Dio(),
        // A bare client for the refresh call itself: routing it through the
        // interceptors below would recurse on its own 401.
        _refreshDio = Dio() {
    for (final client in [_dio, _refreshDio]) {
      client.options
        ..connectTimeout = AppConfig.connectTimeout
        ..receiveTimeout = AppConfig.receiveTimeout
        // Non-2xx is handled by the error interceptor, uniformly.
        ..validateStatus = (status) => status != null && status < 400;
    }
    _applyAddress();
    // The address can change while the app is running, and both clients have to
    // follow it — otherwise a refresh would still go to the old server.
    _address.addListener(_applyAddress);

    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onError: _onError),
    );
  }

  final TokenStore _tokens;
  final ServerAddress _address;
  final Connectivity _connectivity;
  final Dio _dio;
  final Dio _refreshDio;

  Completer<bool>? _refreshInFlight;

  /// Called when the refresh token is rejected and the user must sign in again.
  void Function()? onSessionExpired;

  Dio get dio => _dio;

  void _applyAddress() {
    final base = '${_address.url}${AppConfig.apiPrefix}';
    _dio.options.baseUrl = base;
    _refreshDio.options.baseUrl = base;
  }

  void dispose() {
    _address.removeListener(_applyAddress);
    _dio.close(force: true);
    _refreshDio.close(force: true);
  }

  /// Throws [NetworkException] when the device has no usable connection.
  ///
  /// Cheap insurance before a multi-megabyte upload: without it the user waits
  /// out the full connect timeout to learn they are offline.
  Future<void> requireConnection() async {
    final results = await _connectivity.checkConnectivity();
    final offline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (offline) {
      throw const NetworkException(
        'You appear to be offline. Connect to a network and try again.',
      );
    }
  }

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[_skipAuth] != true) {
      if (_tokens.needsRefresh && _tokens.refreshToken != null) {
        await _refreshTokens();
      }
      final token = _tokens.accessToken;
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  Future<void> _onError(DioException error, ErrorInterceptorHandler handler) async {
    final options = error.requestOptions;
    final isAuthFailure = error.response?.statusCode == 401;
    final alreadyRetried = options.extra[_retried] == true;
    // A consumed FormData stream cannot be replayed; proactive refresh in
    // _onRequest is what keeps uploads from landing here.
    final isReplayable = options.data is! FormData;

    if (isAuthFailure &&
        !alreadyRetried &&
        isReplayable &&
        options.extra[_skipAuth] != true &&
        _tokens.refreshToken != null) {
      final refreshed = await _refreshTokens();
      if (refreshed) {
        options.extra[_retried] = true;
        try {
          final response = await _dio.fetch<dynamic>(options);
          return handler.resolve(response);
        } on DioException catch (retryError) {
          return handler.reject(retryError.copyWith(error: ApiException.from(retryError)));
        }
      }
    }

    handler.reject(error.copyWith(error: ApiException.from(error)));
  }

  /// Rotates the token pair. Concurrent callers share one in-flight refresh.
  Future<bool> _refreshTokens() async {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight.future;

    final completer = Completer<bool>();
    _refreshInFlight = completer;

    try {
      final refresh = _tokens.refreshToken;
      if (refresh == null) {
        completer.complete(false);
        return false;
      }

      final response = await _refreshDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': refresh},
      );
      final body = response.data!;
      await _tokens.save(
        access: body['access_token'] as String,
        refresh: body['refresh_token'] as String,
        expiresInSeconds: body['expires_in'] as int,
      );
      completer.complete(true);
      return true;
    } on DioException catch (error) {
      // A rejected refresh token is terminal: the session is over. A network
      // blip is not — keep the session and let the caller see the failure.
      if (error.response?.statusCode == 401) {
        await _tokens.clear();
        onSessionExpired?.call();
      }
      completer.complete(false);
      return false;
    } finally {
      _refreshInFlight = null;
    }
  }

  static const _skipAuth = 'skipAuth';
  static const _retried = 'retried';

  /// Marks a request as not needing (or wanting) a bearer token.
  static Map<String, dynamic> get unauthenticated => {_skipAuth: true};
}
