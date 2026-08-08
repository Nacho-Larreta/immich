enum OfflineErrorCode {
  cacheMiss,
  mediaNotLocal,
  iCloudUnavailable,
  cancelled,
  timeout,
  serverUnavailable,
  wrongServer,
  unauthorized,
  credentialPurgeFailed,
}

enum OperationCompletion { completed }

sealed class OfflineResult<T> {
  const OfflineResult();

  const factory OfflineResult.success(T value) = OfflineSuccess<T>;
  const factory OfflineResult.failure(OfflineErrorCode error) = OfflineFailure<T>;

  T? get valueOrNull => switch (this) {
    OfflineSuccess<T>(:final value) => value,
    OfflineFailure<T>() => null,
  };

  OfflineErrorCode? get errorOrNull => switch (this) {
    OfflineSuccess<T>() => null,
    OfflineFailure<T>(:final error) => error,
  };
}

final class OfflineSuccess<T> extends OfflineResult<T> {
  const OfflineSuccess(this.value);

  final T value;

  @override
  bool operator ==(Object other) => other is OfflineSuccess<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class OfflineFailure<T> extends OfflineResult<T> {
  const OfflineFailure(this.error);

  final OfflineErrorCode error;

  @override
  bool operator ==(Object other) => other is OfflineFailure<T> && other.error == error;

  @override
  int get hashCode => error.hashCode;
}
