import 'package:dio/dio.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/token_store.dart';

/// Talks to `/auth/*` and owns writing the resulting session to the keystore.
class AuthRepository {
  AuthRepository({required ApiClient client, required TokenStore tokens})
      : _client = client,
        _tokens = tokens;

  final ApiClient _client;
  final TokenStore _tokens;

  Future<void> register({
    required String email,
    required String password,
    String? fullName,
  }) =>
      _postForSession('/auth/register', {
        'email': email,
        'password': password,
        if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
      });

  Future<void> login({required String email, required String password}) =>
      _postForSession('/auth/login', {'email': email, 'password': password});

  /// Revokes this device's refresh token, then clears local state.
  ///
  /// Local state is cleared even if the call fails — the user asked to be
  /// signed out, and a network error should not leave them signed in.
  Future<void> logout() async {
    final refresh = _tokens.refreshToken;
    try {
      if (refresh != null) {
        await _client.dio.post<void>(
          '/auth/logout',
          data: {'refresh_token': refresh},
        );
      }
    } on DioException {
      // Deliberately ignored — see above.
    } finally {
      await _tokens.clear();
    }
  }

  Future<void> _postForSession(String path, Map<String, dynamic> body) async {
    try {
      final response = await _client.dio.post<Map<String, dynamic>>(
        path,
        data: body,
        // There is no session yet; skip the auth interceptor entirely.
        options: Options(extra: ApiClient.unauthenticated),
      );
      final data = response.data!;
      await _tokens.save(
        access: data['access_token'] as String,
        refresh: data['refresh_token'] as String,
        expiresInSeconds: data['expires_in'] as int,
      );
    } on DioException catch (error) {
      throw error.asApiException;
    }
  }
}
