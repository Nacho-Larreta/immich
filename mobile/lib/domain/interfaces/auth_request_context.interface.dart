abstract interface class AuthRequestContextPort {
  void block();

  Future<void> purge();

  void publishCleared();
}
