abstract interface class AuthRequestContextPort {
  void block();

  Future<void> purge();

  void publishCleared();
}

abstract interface class AuthApiGraphPort {
  Future<void> purge();
}
