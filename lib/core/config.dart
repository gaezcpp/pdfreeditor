import 'package:flutter/foundation.dart';

import 'platform/current_host.dart';

/// Build-time configuration.
///
/// Override the backend location without touching code:
/// `flutter run --dart-define=API_BASE_URL=https://api.example.com`
abstract final class AppConfig {
  static const String _override = String.fromEnvironment('API_BASE_URL');

  /// Where the FastAPI backend lives, unless the user overrides it on the
  /// device — see `core/api/server_address.dart`.
  ///
  /// The Android emulator reaches the host machine at 10.0.2.2, not localhost —
  /// getting this wrong is the usual cause of "could not reach the server" on a
  /// first run.
  ///
  /// `kIsWeb` has to be checked first: `defaultTargetPlatform` reports the
  /// *underlying OS*, so Chrome running on an Android phone answers `android`
  /// and would otherwise be sent to the emulator's host address.
  static const int _devPort = 8000;

  /// The emulator's route to the host machine, where `docker compose up`
  /// serves the backend. Physical devices on the LAN use the hidden override
  /// (5 taps on the sign-in logo) when the laptop's address differs.
  static const String _androidDevHost = '10.0.2.2';

  static String get defaultBaseUrl {
    if (_override.isNotEmpty) return _override;

    // On the web, assume the backend runs on whichever machine served the page.
    // Opened from a phone at http://192.168.1.23:5000 this resolves to
    // http://192.168.1.23:8000, where a hard-coded `localhost` would mean the
    // phone itself and fail with a network error that explains nothing.
    if (kIsWeb) {
      return 'http://${currentHost ?? 'localhost'}:$_devPort';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://$_androidDevHost:$_devPort';
    }
    return 'http://localhost:$_devPort';
  }

  static const String apiPrefix = '/api/v1';

  /// Set with `--dart-define=TELEGRAM_USERNAME=...` and
  /// `--dart-define=WHATSAPP_NUMBER=...` for manual premium sales.
  static const String telegramUsername =
      String.fromEnvironment('TELEGRAM_USERNAME', defaultValue: 'sherdderz');
  static const String whatsappNumber =
      String.fromEnvironment('WHATSAPP_NUMBER', defaultValue: '6289618547500');

  /// Mirrors the backend's own cap, so an oversized file is caught before it
  /// is uploaded rather than after.
  static const int maxUploadBytes = 25 * 1024 * 1024;

  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(minutes: 3);
}
