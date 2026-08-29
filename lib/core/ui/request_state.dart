import '../api/api_exception.dart';

/// The four states every API-backed screen can be in.
///
/// [QuotaExceeded] is split out from [Failure] deliberately: it is not an error
/// the user should "try again" past, it is the paywall trigger. Keeping it a
/// distinct case means a screen that forgets to handle it fails to compile
/// rather than showing a generic red banner over the upsell.
sealed class RequestState<T> {
  const RequestState();

  const factory RequestState.idle() = Idle<T>;
  const factory RequestState.loading() = Loading<T>;
  const factory RequestState.success(T value) = Success<T>;

  /// Routes quota failures to [QuotaExceeded] so callers cannot conflate them.
  factory RequestState.failed(ApiException error) => switch (error) {
        QuotaExceededException() => QuotaExceeded<T>(error),
        _ => Failure<T>(error),
      };

  bool get isLoading => this is Loading<T>;
  T? get valueOrNull => this is Success<T> ? (this as Success<T>).value : null;
}

final class Idle<T> extends RequestState<T> {
  const Idle();
}

final class Loading<T> extends RequestState<T> {
  const Loading();
}

final class Success<T> extends RequestState<T> {
  const Success(this.value);
  final T value;
}

final class Failure<T> extends RequestState<T> {
  const Failure(this.error);
  final ApiException error;
}

final class QuotaExceeded<T> extends RequestState<T> {
  const QuotaExceeded(this.error);
  final QuotaExceededException error;
}
