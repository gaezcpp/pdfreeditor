import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where a finished document should be written.
enum SaveDestination {
  /// Show the system save dialog and let the user pick the folder.
  ///
  /// On Android this is the only way a saved file lands somewhere the person
  /// can actually open later: the app's own directory is private storage that
  /// no file manager can see.
  ask,

  /// Write straight into the app's documents folder, no dialog.
  ///
  /// Faster for repeated saves, but on Android the result is only reachable
  /// from inside this app.
  appFolder;

  String get label => switch (this) {
        SaveDestination.ask => 'Ask where to save',
        SaveDestination.appFolder => 'App folder',
      };

  String get description => switch (this) {
        SaveDestination.ask =>
          'Choose the folder each time. The file shows up in your file manager.',
        SaveDestination.appFolder =>
          'No dialog, but on Android only this app can open the result.',
      };
}

/// Remembers the chosen destination.
///
/// Defaults to [SaveDestination.ask] because the alternative hides the file:
/// a saved PDF that cannot be found is the same as one that was never saved.
class SaveDestinationStore extends ChangeNotifier {
  SaveDestinationStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'save_destination';

  final FlutterSecureStorage _storage;
  SaveDestination _value = SaveDestination.ask;

  SaveDestination get value => _value;

  Future<void> load() async {
    try {
      final stored = await _storage.read(key: _key);
      _value = SaveDestination.values.firstWhere(
        (destination) => destination.name == stored,
        orElse: () => SaveDestination.ask,
      );
    } catch (_) {
      _value = SaveDestination.ask;
    }
  }

  Future<void> set(SaveDestination destination) async {
    if (destination == _value) return;
    _value = destination;
    notifyListeners();

    try {
      await _storage.write(key: _key, value: destination.name);
    } catch (error) {
      debugPrint('Could not remember the save destination: $error');
    }
  }
}
