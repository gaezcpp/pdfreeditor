import 'package:flutter_test/flutter_test.dart';
import 'package:pdfreeditor/features/user/user_status.dart';

Map<String, dynamic> _payload({
  int? limit = 5,
  int used = 2,
  int? remaining = 3,
  bool isPremium = false,
  String? premiumUntil,
}) =>
    {
      'user': {
        'id': '9a1f5b1e-0000-4000-8000-000000000000',
        'email': 'a@example.com',
        'full_name': null,
        'plan': isPremium ? 'premium' : 'free',
        'created_at': '2026-08-01T10:00:00+00:00',
      },
      'is_premium': isPremium,
      'premium_until': premiumUntil,
      'quota': {
        'limit': limit,
        'used': used,
        'remaining': remaining,
        'period_start': '2026-08-24T00:00:00+00:00',
        'period_end': '2026-08-31T00:00:00+00:00',
      },
    };

void main() {
  test('parses a free user', () {
    final status = UserStatus.fromJson(_payload());

    expect(status.isPremium, isFalse);
    expect(status.quota.limit, 5);
    expect(status.quota.remaining, 3);
    expect(status.quota.isUnlimited, isFalse);
    expect(status.quota.isExhausted, isFalse);
  });

  test('reads a null limit as unlimited rather than zero', () {
    final status = UserStatus.fromJson(
      _payload(limit: null, remaining: null, used: 0, isPremium: true),
    );

    expect(status.quota.isUnlimited, isTrue);
    expect(status.quota.isExhausted, isFalse);
    expect(status.quota.fractionUsed, 0);
  });

  test('flags an exhausted quota', () {
    final status = UserStatus.fromJson(_payload(used: 5, remaining: 0));

    expect(status.quota.isExhausted, isTrue);
    expect(status.quota.fractionUsed, 1);
  });

  test('converts UTC timestamps to local time', () {
    final status = UserStatus.fromJson(_payload());

    expect(status.quota.periodEnd.isUtc, isFalse);
    expect(status.quota.periodEnd.toUtc(), DateTime.utc(2026, 8, 31));
  });

  test('falls back to the email when no name is set', () {
    final status = UserStatus.fromJson(_payload());

    expect(status.user.displayName, 'a@example.com');
  });
}
