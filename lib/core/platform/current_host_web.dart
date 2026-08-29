import 'package:web/web.dart' as web;

/// The hostname in the browser's address bar.
///
/// This is what makes a web build work when it is opened from another device.
/// Hard-coding `localhost` would be read by the phone as *the phone*, so the
/// app would look for a backend on the handset and fail with a network error
/// that says nothing about the real cause.
String? get currentHost {
  final host = web.window.location.hostname;
  return host.isEmpty ? null : host;
}
