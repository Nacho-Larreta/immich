import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/infrastructure/cancel.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:worker_manager/worker_manager.dart';

class InvalidIsolateUsageException implements Exception {
  const InvalidIsolateUsageException();

  @override
  String toString() => "IsolateHelper should only be used from the root isolate";
}

// !! Should be used only from the root isolate
Cancelable<T?> runInIsolateGentle<T, A>({
  required Future<T> Function(ProviderContainer ref, A argument) computation,
  required A argument,
  String? debugLabel,
}) {
  final token = RootIsolateToken.instance;
  if (token == null) {
    throw const InvalidIsolateUsageException();
  }

  return workerManagerPatch.executeGentle((cancelledChecker) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    DartPluginRegistrant.ensureInitialized();

    final (drift, logDb) = await Bootstrap.initDomain(
      shouldBufferLogs: false,
      listenStoreUpdates: false,
      networkContextRole: NetworkContextRole.attachedWorker,
    );
    final ref = ProviderContainer(
      overrides: [
        cancellationProvider.overrideWithValue(cancelledChecker),
        driftProvider.overrideWith(driftOverride(drift)),
      ],
    );

    return executeBackgroundComputation(
      computation: () => computation(ref, argument),
      cleanup: () async {
        try {
          ref.dispose();
          await Store.dispose();
          await LogService.I.dispose();
          await logDb.close();
          await drift.close();
        } catch (error, stack) {
          dPrint(() => "Error closing resources in isolate: $error, $stack");
        } finally {
          await Future.delayed(const Duration(seconds: 2));
        }
      },
    );
  });
}

Future<T> executeBackgroundComputation<T>({
  required Future<T> Function() computation,
  required Future<void> Function() cleanup,
}) async {
  try {
    return await computation();
  } finally {
    await cleanup();
  }
}
