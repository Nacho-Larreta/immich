sealed class LogoutOutcome {
  const LogoutOutcome();

  bool get didClearSession => this is LogoutSuccess || this is LogoutClearedWithWarning;
}

final class LogoutSuccess extends LogoutOutcome {
  const LogoutSuccess();
}

final class LogoutClearedWithWarning extends LogoutOutcome {
  const LogoutClearedWithWarning(this.warning);

  final Object warning;
}

final class LogoutNotCleared extends LogoutOutcome {
  const LogoutNotCleared(this.error);

  final Object error;
}
