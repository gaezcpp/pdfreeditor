/// Mirrors `GET /api/v1/users/me/status`.
class UserStatus {
  const UserStatus({
    required this.user,
    required this.isPremium,
    required this.premiumUntil,
    required this.quota,
  });

  final AppUser user;
  final bool isPremium;
  final DateTime? premiumUntil;
  final Quota quota;

  factory UserStatus.fromJson(Map<String, dynamic> json) => UserStatus(
        user: AppUser.fromJson((json['user'] as Map).cast<String, dynamic>()),
        isPremium: json['is_premium'] as bool,
        premiumUntil: _parseUtc(json['premium_until']),
        quota: Quota.fromJson((json['quota'] as Map).cast<String, dynamic>()),
      );
}

class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    required this.fullName,
    required this.plan,
  });

  final String id;
  final String email;
  final String? fullName;
  final String plan;

  String get displayName => (fullName?.isNotEmpty ?? false) ? fullName! : email;

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        email: json['email'] as String,
        fullName: json['full_name'] as String?,
        plan: json['plan'] as String,
      );
}

/// The weekly edit allowance.
///
/// [limit] and [remaining] are null for premium users — the backend sends null
/// rather than a sentinel, so "unlimited" is the absence of a number.
class Quota {
  const Quota({
    required this.limit,
    required this.used,
    required this.remaining,
    required this.periodStart,
    required this.periodEnd,
  });

  final int? limit;
  final int used;
  final int? remaining;
  final DateTime periodStart;
  final DateTime periodEnd;

  bool get isUnlimited => limit == null;
  bool get isExhausted => remaining != null && remaining! <= 0;

  double get fractionUsed {
    final total = limit;
    if (total == null || total == 0) return 0;
    return (used / total).clamp(0, 1).toDouble();
  }

  factory Quota.fromJson(Map<String, dynamic> json) => Quota(
        limit: json['limit'] as int?,
        used: json['used'] as int,
        remaining: json['remaining'] as int?,
        periodStart: _parseUtc(json['period_start'])!,
        periodEnd: _parseUtc(json['period_end'])!,
      );
}

/// The backend sends UTC ISO-8601; show it in the device's zone.
DateTime? _parseUtc(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
