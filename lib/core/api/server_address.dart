import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';

/// Where the app talks to, changeable at runtime.
///
/// The build-time default is compiled in and is right for the emulator and for
/// a shipped app, but wrong the moment a real phone points at a laptop whose
/// DHCP lease moved. Rebuilding the APK for a new IP is a poor loop, so the
/// address can be overridden on the device and remembered.
///
/// An empty override means "use the compiled-in default", so clearing the field
/// gets you back to a working app rather than a broken one.
class ServerAddress extends ChangeNotifier {
  ServerAddress({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'server_base_url';

  final FlutterSecureStorage _storage;
  String? _override;

  /// The address currently in use, for code that cannot reach an instance.
  ///
  /// One process talks to one backend, so a single value is the whole truth.
  /// It exists so error messages can name the host that failed without every
  /// call site having to carry the store around.
  static String activeUrl = AppConfig.defaultBaseUrl;

  /// The override the user set, or null when the built-in default is in use.
  String? get override => _override;

  String get url => _override ?? AppConfig.defaultBaseUrl;

  bool get isDefault => _override == null;

  String get defaultUrl => AppConfig.defaultBaseUrl;

  /// Human-readable host and port, for a settings row.
  String get label {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  Future<void> load() async {
    try {
      _override = _clean(await _storage.read(key: _key));
    } catch (_) {
      // A locked or unavailable keystore should not stop the app starting;
      // the compiled-in default still works.
      _override = null;
    }
    activeUrl = url;
  }

  /// Stores a new address, or clears the override when [input] is blank.
  ///
  /// Returns true when the address actually changed.
  Future<bool> set(String? input) async {
    final normalized = normalize(input);
    if (normalized == _override) return false;

    _override = normalized;
    activeUrl = url;
    // Switch first, persist second. If the keystore is unavailable the change
    // still takes effect for this session, which is better than refusing to
    // let someone point the app at a reachable server.
    notifyListeners();

    try {
      if (normalized == null) {
        await _storage.delete(key: _key);
      } else {
        await _storage.write(key: _key, value: normalized);
      }
    } catch (error, stack) {
      debugPrint('Could not remember the server address: $error');
      debugPrintStack(stackTrace: stack);
    }
    return true;
  }

  /// Trims an address down to scheme, host, and port.
  ///
  /// The API prefix is appended by the client, so a pasted `.../api/v1` or a
  /// trailing slash would otherwise produce a doubled path that 404s.
  static String? normalize(String? input) {
    final raw = input?.trim() ?? '';
    if (raw.isEmpty) return null;

    final withScheme = raw.contains('://') ? raw : 'http://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;

    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  /// Null when [input] is usable, otherwise why it is not.
  static String? validate(String? input) {
    final raw = input?.trim() ?? '';
    if (raw.isEmpty) return null; // blank is allowed: it means "use the default"

    final withScheme = raw.contains('://') ? raw : 'http://$raw';
    final uri = Uri.tryParse(withScheme);

    if (uri == null || uri.host.isEmpty) {
      return 'Enter an address like 192.168.1.23:8000';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'Only http and https addresses work.';
    }
    return null;
  }

  static String? _clean(String? stored) =>
      (stored == null || stored.isEmpty) ? null : stored;
}
