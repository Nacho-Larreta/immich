import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';

/// Owns the app-scoped lock for every mutation that can replace or clear the
/// active session. Endpoint activation wiring must consume this exact provider
/// so activation and logout cannot publish interleaved session state.
final sessionMutationMutexProvider = Provider<SessionMutationMutex>((_) => SessionMutationMutex());
