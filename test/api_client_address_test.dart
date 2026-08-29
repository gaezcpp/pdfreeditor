import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/api/api_client.dart';
import 'package:pdfreeditor/core/api/server_address.dart';
import 'package:pdfreeditor/core/api/token_store.dart';
import 'package:pdfreeditor/core/config.dart';

/// The point of a runtime server address is that requests actually follow it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Stand in for the platform keystore so persistence can be exercised, not
  // just tolerated.
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> keystore;

  late ServerAddress address;
  late Dio dio;
  late ApiClient client;

  setUp(() {
    keystore = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final key = call.arguments['key'] as String?;
      switch (call.method) {
        case 'write':
          keystore[key!] = call.arguments['value'] as String;
          return null;
        case 'read':
          return keystore[key];
        case 'delete':
          keystore.remove(key);
          return null;
        case 'readAll':
          return keystore;
        case 'deleteAll':
          // Modelled faithfully on purpose: this is the call that used to wipe
          // the saved address along with the tokens.
          keystore.clear();
          return null;
        default:
          return null;
      }
    });

    address = ServerAddress();
    dio = Dio();
    client = ApiClient(tokens: TokenStore(), address: address, dio: dio);
  });

  tearDown(() {
    client.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('starts on the compiled-in default', () {
    expect(dio.options.baseUrl, '${AppConfig.defaultBaseUrl}${AppConfig.apiPrefix}');
  });

  test('follows the address when it changes', () async {
    await address.set('192.168.1.23:8000');

    expect(dio.options.baseUrl, 'http://192.168.1.23:8000${AppConfig.apiPrefix}');
  });

  test('goes back to the default when the override is cleared', () async {
    await address.set('192.168.1.23:8000');
    await address.set('');

    expect(dio.options.baseUrl, '${AppConfig.defaultBaseUrl}${AppConfig.apiPrefix}');
    expect(address.isDefault, isTrue);
  });

  test('publishes the active address for error messages', () async {
    await address.set('10.0.0.7:9000');

    // api_exception names this host when a connection fails in debug builds.
    expect(ServerAddress.activeUrl, 'http://10.0.0.7:9000');
  });

  test('stops following once disposed', () async {
    client.dispose();
    final before = dio.options.baseUrl;

    await address.set('192.168.1.23:8000');

    expect(dio.options.baseUrl, before);
  });

  test('label shows host and port', () async {
    await address.set('192.168.1.23:8000');
    expect(address.label, '192.168.1.23:8000');
  });

  test('remembers the address across a restart', () async {
    await address.set('192.168.1.23:8000');

    // A fresh instance, as if the app had been relaunched.
    final restarted = ServerAddress();
    await restarted.load();

    expect(restarted.override, 'http://192.168.1.23:8000');
    expect(restarted.isDefault, isFalse);
  });

  test('signing out does not forget the address', () async {
    await address.set('192.168.1.23:8000');
    final tokens = TokenStore();
    await tokens.save(access: 'a', refresh: 'r', expiresInSeconds: 60);

    // `clear` used to wipe the whole keystore, taking this with it.
    await tokens.clear();

    final restarted = ServerAddress();
    await restarted.load();
    expect(restarted.override, 'http://192.168.1.23:8000');
  });
}
