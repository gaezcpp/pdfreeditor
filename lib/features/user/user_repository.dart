import 'package:dio/dio.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import 'user_status.dart';

class UserRepository {
  UserRepository(this._client);

  final ApiClient _client;

  /// Plan, premium expiry, and remaining quota — everything the paywall and the
  /// quota badge read, in one call.
  Future<UserStatus> fetchStatus() async {
    try {
      final response =
          await _client.dio.get<Map<String, dynamic>>('/users/me/status');
      return UserStatus.fromJson(response.data!);
    } on DioException catch (error) {
      throw error.asApiException;
    }
  }

  Future<void> requestPremium() async {
    try {
      await _client.dio.post<void>('/users/me/premium-request');
    } on DioException catch (error) {
      throw error.asApiException;
    }
  }
}
