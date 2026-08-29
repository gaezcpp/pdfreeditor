import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/features/user/quota_card.dart';
import 'package:pdfreeditor/features/user/user_status.dart';

UserStatus _status({
  required bool isPremium,
  int? limit = 5,
  int used = 2,
  int? remaining = 3,
}) =>
    UserStatus(
      user: const AppUser(
        id: 'id',
        email: 'a@example.com',
        fullName: null,
        plan: 'free',
      ),
      isPremium: isPremium,
      premiumUntil: null,
      quota: Quota(
        limit: limit,
        used: used,
        remaining: remaining,
        periodStart: DateTime(2026, 8, 24),
        periodEnd: DateTime(2026, 8, 31, 7),
      ),
    );

Future<void> _pump(WidgetTester tester, UserStatus status, {VoidCallback? onUpgrade}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: QuotaCard(status: status, onUpgrade: onUpgrade ?? () {}),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the remaining count and the reset date for free users',
      (tester) async {
    await _pump(tester, _status(isPremium: false));

    expect(find.text('3 of 5 edits left'), findsOneWidget);
    expect(find.textContaining('Resets Mon 31 Aug'), findsOneWidget);
    expect(find.text('Go unlimited'), findsOneWidget);
  });

  testWidgets('says so plainly when the week is used up', (tester) async {
    await _pump(tester, _status(isPremium: false, used: 5, remaining: 0));

    expect(find.text('No edits left this week'), findsOneWidget);
  });

  testWidgets('replaces the counter with the premium badge', (tester) async {
    await _pump(
      tester,
      _status(isPremium: true, limit: null, used: 0, remaining: null),
    );

    expect(find.text('Premium — unlimited edits'), findsOneWidget);
    // Nothing to upsell to a subscriber.
    expect(find.text('Go unlimited'), findsNothing);
  });

  testWidgets('the upgrade button reaches the paywall callback', (tester) async {
    var tapped = false;
    await _pump(tester, _status(isPremium: false), onUpgrade: () => tapped = true);

    await tester.tap(find.text('Go unlimited'));
    expect(tapped, isTrue);
  });
}
