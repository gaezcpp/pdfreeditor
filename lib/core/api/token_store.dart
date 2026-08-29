import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Session tokens, kept in the platform keystore rather than shared prefs.
///
/// The access token is cached in memory after the first read so the hot path
/// (every API call) does not hit the keystore, which is slow on Android.
class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Android defaults to AES-GCM with KeyStore-wrapped keys.
              aOptions: AndroidOptions(),
              // first_unlock, not always: the tokens should not be readable
              // while the device is locked, but background refresh still works.
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _expiresKey = 'access_expires_at';

  /// Refresh this far before the real expiry, so a token cannot lapse midway
  /// through a slow upload.
  static const _skew = Duration(minutes: 2);

  final FlutterSecureStorage _storage;

  String? _access;
  String? _refresh;
  DateTime? _expiresAt;
  bool _loaded = false;

  String? get accessToken => _access;
  String? get refreshToken => _refresh;
  bool get hasSession => _refresh != null;

  /// True when the access token is gone or close enough to expiry to be unsafe.
  bool get needsRefresh {
    if (_access == null) return true;
    final expiry = _expiresAt;
    if (expiry == null) return false;
    return DateTime.now().toUtc().isAfter(expiry.subtract(_skew));
  }

  /// Reads the session from the keystore once, at startup.
  Future<void> load() async {
    if (_loaded) return;
    _access = await _storage.read(key: _accessKey);
    _refresh = await _storage.read(key: _refreshKey);
    final rawExpiry = await _storage.read(key: _expiresKey);
    _expiresAt = rawExpiry == null ? null : DateTime.tryParse(rawExpiry);
    _loaded = true;
  }

  Future<void> save({
    required String access,
    required String refresh,
    required int expiresInSeconds,
  }) async {
    _access = access;
    _refresh = refresh;
    _expiresAt = DateTime.now().toUtc().add(Duration(seconds: expiresInSeconds));
    _loaded = true;
    await _storage.write(key: _accessKey, value: access);
    await _storage.write(key: _refreshKey, value: refresh);
    await _storage.write(key: _expiresKey, value: _expiresAt!.toIso8601String());
  }

  Future<void> clear() async {
    _access = null;
    _refresh = null;
    _expiresAt = null;
    _loaded = true;
    // Only this store's keys. `deleteAll` would also wipe unrelated settings
    // kept in the same keystore — the configured server address among them.
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _expiresKey);
  }
}
