import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/token_store.dart';
import '../../core/ui/request_state.dart';
import '../user/user_repository.dart';
import '../user/user_status.dart';
import 'auth_repository.dart';

enum SessionPhase { starting, signedOut, signedIn }

/// Owns "who is signed in and what are they entitled to" for the whole app.
///
/// The quota lives here rather than on each tool screen so every screen shows
/// the same number, and so an edit can update the badge from the response
/// header without a second round trip.
class SessionController extends ChangeNotifier {
  SessionController({
    required ApiClient client,
    required AuthRepository auth,
    required UserRepository users,
    required TokenStore tokens,
  })  : _auth = auth,
        _users = users,
        _tokens = tokens {
    // A refresh token rejected mid-flight ends the session from below.
    client.onSessionExpired = _handleSessionExpired;
  }

  final AuthRepository _auth;
  final UserRepository _users;
  final TokenStore _tokens;

  SessionPhase _phase = SessionPhase.starting;
  UserStatus? _status;
  RequestState<void> _authRequest = const RequestState<void>.idle();
  String? _expiryNotice;

  SessionPhase get phase => _phase;
  UserStatus? get status => _status;
  Quota? get quota => _status?.quota;
  bool get isPremium => _status?.isPremium ?? false;

  /// State of the in-progress sign-in or sign-up, for the auth form.
  RequestState<void> get authRequest => _authRequest;

  /// Set when the session ended on its own, so the login screen can explain why.
  String? get expiryNotice => _expiryNotice;

  /// Restores a stored session at startup, if there is one.
  Future<void> bootstrap() async {
    await _tokens.load();
    if (!_tokens.hasSession) {
      _setPhase(SessionPhase.signedOut);
      return;
    }
    // Tokens on disk are not proof of a live session — the status call is.
    final ok = await _loadStatus();
    _setPhase(ok ? SessionPhase.signedIn : SessionPhase.signedOut);
  }

  Future<bool> login({required String email, required String password}) =>
      _authenticate(() => _auth.login(email: email, password: password));

  Future<void> requestPasswordReset(String email) =>
      _auth.requestPasswordReset(email);

  Future<bool> register({
    required String email,
    required String password,
    String? fullName,
  }) =>
      _authenticate(
        () => _auth.register(email: email, password: password, fullName: fullName),
      );

  Future<void> logout() async {
    await _auth.logout();
    _status = null;
    _expiryNotice = null;
    _setPhase(SessionPhase.signedOut);
  }

  /// Ends the session after the server address changed.
  ///
  /// Tokens are issued by one backend and meaningless to another, so staying
  /// "signed in" across a switch would only produce confusing 401s.
  Future<void> handleServerChanged() async {
    await _tokens.clear();
    _status = null;
    _expiryNotice = 'Server changed. Please sign in again.';
    _setPhase(SessionPhase.signedOut);
  }

  /// Re-reads plan and quota. Called on launch, on pull-to-refresh, and after
  /// the paywall, where a purchase may have changed the plan.
  Future<void> refreshStatus() async {
    await _loadStatus();
    notifyListeners();
  }

  Future<void> requestPremium() => _users.requestPremium();

  /// Applies the `X-Quota-Remaining` header from a completed edit.
  ///
  /// Cheaper than refetching the status, and it keeps the badge honest the
  /// instant an edit lands.
  void applyQuotaAfterEdit(int? remaining) {
    final current = _status;
    if (current == null || remaining == null || current.quota.isUnlimited) return;

    _status = UserStatus(
      user: current.user,
      isPremium: current.isPremium,
      premiumUntil: current.premiumUntil,
      quota: Quota(
        limit: current.quota.limit,
        used: (current.quota.limit ?? 0) - remaining,
        remaining: remaining,
        periodStart: current.quota.periodStart,
        periodEnd: current.quota.periodEnd,
      ),
    );
    notifyListeners();
  }

  void clearAuthRequest() {
    _authRequest = const RequestState<void>.idle();
    notifyListeners();
  }

  Future<bool> _authenticate(Future<void> Function() action) async {
    _authRequest = const RequestState<void>.loading();
    _expiryNotice = null;
    notifyListeners();

    try {
      await action();
      await _loadStatus();
      _authRequest = const RequestState<void>.success(null);
      _setPhase(SessionPhase.signedIn);
      return true;
    } on ApiException catch (error) {
      _authRequest = RequestState<void>.failed(error);
      notifyListeners();
      return false;
    }
  }

  Future<bool> _loadStatus() async {
    try {
      _status = await _users.fetchStatus();
      return true;
    } on UnauthenticatedException {
      await _tokens.clear();
      return false;
    } on ApiException {
      // A network hiccup should not sign the user out; keep whatever we had.
      return _status != null;
    }
  }

  void _handleSessionExpired() {
    _status = null;
    _expiryNotice = 'Your session expired. Please sign in again.';
    _setPhase(SessionPhase.signedOut);
  }

  void _setPhase(SessionPhase phase) {
    _phase = phase;
    notifyListeners();
  }
}
