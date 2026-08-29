import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/api/server_address.dart';

/// Address parsing, which is where a typed-in server address goes wrong.
///
/// The client appends `/api/v1` itself, so anything left on the end of what the
/// user typed becomes a doubled path and a 404 that looks like a server fault.
void main() {
  group('normalize', () {
    test('assumes http when no scheme is given', () {
      expect(
        ServerAddress.normalize('192.168.1.23:8000'),
        'http://192.168.1.23:8000',
      );
    });

    test('keeps an explicit https scheme', () {
      expect(
        ServerAddress.normalize('https://api.example.com'),
        'https://api.example.com',
      );
    });

    test('drops a trailing slash', () {
      expect(
        ServerAddress.normalize('http://192.168.1.23:8000/'),
        'http://192.168.1.23:8000',
      );
    });

    test('drops a pasted api path', () {
      // Copying the URL out of /docs is the obvious thing to do, and it would
      // otherwise produce /api/v1/api/v1/... on every call.
      expect(
        ServerAddress.normalize('http://192.168.1.23:8000/api/v1'),
        'http://192.168.1.23:8000',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        ServerAddress.normalize('  192.168.1.23:8000  '),
        'http://192.168.1.23:8000',
      );
    });

    test('keeps a host with no port', () {
      expect(
        ServerAddress.normalize('api.example.com'),
        'http://api.example.com',
      );
    });

    test('blank means "use the default"', () {
      expect(ServerAddress.normalize(''), isNull);
      expect(ServerAddress.normalize('   '), isNull);
      expect(ServerAddress.normalize(null), isNull);
    });
  });

  group('validate', () {
    test('accepts a bare host and port', () {
      expect(ServerAddress.validate('192.168.1.23:8000'), isNull);
    });

    test('accepts blank, because that resets to the default', () {
      expect(ServerAddress.validate(''), isNull);
      expect(ServerAddress.validate(null), isNull);
    });

    test('rejects a scheme that is not http or https', () {
      expect(ServerAddress.validate('ftp://192.168.1.23'), isNotNull);
      expect(ServerAddress.validate('ws://192.168.1.23:8000'), isNotNull);
    });

    test('rejects input with no host', () {
      expect(ServerAddress.validate('http://'), isNotNull);
      expect(ServerAddress.validate(':::'), isNotNull);
    });
  });
}
