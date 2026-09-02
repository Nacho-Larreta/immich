import 'dart:async';

import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';

final class BackupCallbackFence implements BackupCallbackFencePort {
  final Map<(String, String), _OwnerCallbacks> _owners = {};
  var _nextPermitId = 0;

  @override
  BackupCallbackPermit? tryBegin({required String runToken, required String bindingDigest}) {
    final owner = (runToken, bindingDigest);
    final callbacks = _owners.putIfAbsent(owner, _OwnerCallbacks.new);
    if (callbacks.fenced) return null;
    final permit = BackupCallbackPermit(runToken: runToken, bindingDigest: bindingDigest, permitId: _nextPermitId++);
    callbacks.permitIds.add(permit.permitId);
    return permit;
  }

  @override
  void end(BackupCallbackPermit permit) {
    final owner = (permit.runToken, permit.bindingDigest);
    final callbacks = _owners[owner];
    if (callbacks == null || !callbacks.permitIds.remove(permit.permitId)) return;
    if (callbacks.permitIds.isNotEmpty) return;
    callbacks.drained?.complete();
    callbacks.drained = null;
    if (!callbacks.fenced) _owners.remove(owner);
  }

  @override
  Future<bool> fenceAndDrain({
    required String runToken,
    required String bindingDigest,
    required Duration timeout,
  }) async {
    final callbacks = _owners.putIfAbsent((runToken, bindingDigest), _OwnerCallbacks.new)..fenced = true;
    if (callbacks.permitIds.isEmpty) return true;
    final drained = callbacks.drained ??= Completer<void>();
    try {
      await drained.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

final class _OwnerCallbacks {
  bool fenced = false;
  final Set<int> permitIds = {};
  Completer<void>? drained;
}
