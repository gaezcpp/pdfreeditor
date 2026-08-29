import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/core/api/api_exception.dart';
import 'package:pdfreeditor/core/ui/request_state.dart';

void main() {
  group('RequestState.failed', () {
    test('routes a quota failure to QuotaExceeded, not Failure', () {
      final state = RequestState<int>.failed(
        const QuotaExceededException('Out of edits.'),
      );

      // This is what makes the paywall un-missable: a screen that only handles
      // Failure will not compile against the sealed hierarchy.
      expect(state, isA<QuotaExceeded<int>>());
      expect(state, isNot(isA<Failure<int>>()));
    });

    test('routes every other failure to Failure', () {
      final state = RequestState<int>.failed(
        const NetworkException('Offline.'),
      );

      expect(state, isA<Failure<int>>());
    });
  });

  test('isLoading and valueOrNull reflect the case', () {
    expect(const RequestState<int>.loading().isLoading, isTrue);
    expect(const RequestState<int>.success(7).valueOrNull, 7);
    expect(const RequestState<int>.idle().valueOrNull, isNull);
    expect(const RequestState<int>.loading().valueOrNull, isNull);
  });
}
