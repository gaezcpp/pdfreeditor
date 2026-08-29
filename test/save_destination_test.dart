import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/files/save_destination.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> keystore;

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
          keystore.clear();
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('defaults to asking, so results never land somewhere invisible', () {
    // The app folder is private storage on Android: a file saved there cannot
    // be opened from a file manager, which reads to the user as "lost".
    expect(SaveDestinationStore().value, SaveDestination.ask);
  });

  test('remembers the choice across a restart', () async {
    final store = SaveDestinationStore();
    await store.set(SaveDestination.appFolder);

    final restarted = SaveDestinationStore();
    await restarted.load();

    expect(restarted.value, SaveDestination.appFolder);
  });

  test('notifies listeners when the choice changes', () async {
    final store = SaveDestinationStore();
    var notifications = 0;
    store.addListener(() => notifications++);

    await store.set(SaveDestination.appFolder);
    await store.set(SaveDestination.appFolder); // same value, no-op

    expect(notifications, 1);
  });

  test('falls back to asking when the stored value is unrecognised', () async {
    keystore['save_destination'] = 'some_removed_option';

    final store = SaveDestinationStore();
    await store.load();

    expect(store.value, SaveDestination.ask);
  });

  test('every option describes itself for the settings list', () {
    for (final option in SaveDestination.values) {
      expect(option.label, isNotEmpty);
      expect(option.description, isNotEmpty);
    }
  });
}
