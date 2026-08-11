import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final package = Directory('packages/cupertino_http');

  test('mobile resolves the audited local Cupertino HTTP package', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final lock = File('pubspec.lock').readAsStringSync();

    expect(pubspec, contains('path: packages/cupertino_http'));
    expect(lock, contains('path: "packages/cupertino_http"'));
    expect(lock, contains('source: path'));
  });

  test('native reaper tombstones callbacks and serializes start cancellation', () {
    final source = File(
      '${package.path}/darwin/cupertino_http/Sources/cupertino_http/CUPHTTPStreamingTask.swift',
    ).readAsStringSync();

    expect(source, contains('func reap()'));
    expect(source, contains('tombstoneAndWait'));
    expect(source, contains('cancelRequested'));
    expect(source, contains('guard beginStart()'));
    expect(source, contains('takeRetainedValue()'));
  });

  test('Dart streaming cancellation waits for native didComplete', () {
    final source = File('${package.path}/lib/src/cupertino_api.dart').readAsStringSync();

    expect(source, contains('Future<void> get completed'));
    expect(source, contains('Future<void> cancelAndWait()'));
    expect(source, contains('onCancel: () => task.cancelAndWait()'));
    expect(source, contains('_taskReaper.attach'));
  });

  test('iOS 14 buffered fallback is owned and terminal-drained per client', () {
    final source = File('${package.path}/lib/src/cupertino_client.dart').readAsStringSync();
    final bodyPrepared = source.indexOf("if (!_supportsPerTaskDelegates)");
    final openRevalidation = source.lastIndexOf('if (_urlSession == null)', bodyPrepared);
    final admission = source.indexOf('if (!_bufferedTasks.admit(bufferedTask))');
    final rejectedCancellation = source.indexOf('await cancelRejectedTaskAndWait(', admission);
    final resume = source.indexOf('bufferedTask.resume();', admission);

    expect(source, contains('_bufferedTasks'));
    expect(source, contains('_BufferedTask'));
    expect(source, contains('_bufferedTasks.closeAndDrain()'));
    expect(openRevalidation, greaterThan(source.indexOf('final stream = request.finalize()')));
    expect(admission, greaterThanOrEqualTo(0));
    expect(rejectedCancellation, greaterThan(admission));
    expect(resume, greaterThan(rejectedCancellation));
  });

  test('attached worker cleanup drains network before non-network resources', () {
    final source = File('lib/utils/isolate.dart').readAsStringSync();
    final drain = source.indexOf('drainNetwork: NetworkRepository.drainAttachedWorker');
    final providers = source.indexOf('ref.dispose()');
    final stores = source.indexOf('await Store.dispose()');

    expect(drain, greaterThanOrEqualTo(0));
    expect(providers, greaterThan(drain));
    expect(stores, greaterThan(providers));
  });

  test('native background engines quarantine unsafe cleanup failures', () {
    final swift = File('ios/Runner/Background/BackgroundWorker.swift').readAsStringSync();
    final kotlin = File(
      'android/app/src/main/kotlin/app/alextran/immich/background/BackgroundWorker.kt',
    ).readAsStringSync();

    expect(swift, contains('unsafe-to-terminate'));
    expect(swift, contains('isQuarantined'));
    expect(kotlin, contains('unsafe-to-terminate'));
    expect(kotlin, contains('isQuarantined'));
  });

  test('native background worker drains before releasing its engine resources', () {
    final source = File('lib/domain/services/background_worker.service.dart').readAsStringSync();
    final cleanup = source.indexOf('Future<void> _handleCleanup()');
    final drain = source.indexOf('await drainNetworkBeforeRelease(', cleanup);
    final drift = source.indexOf('await _drift.close()', drain);
    final providers = source.indexOf('_ref?.dispose()', drain);
    final stores = source.indexOf('Store.dispose()', drain);

    expect(cleanup, greaterThanOrEqualTo(0));
    expect(drain, greaterThan(cleanup));
    expect(drift, greaterThan(drain));
    expect(providers, greaterThan(drain));
    expect(stores, greaterThan(drain));
    expect(source, isNot(contains('Error during background worker cleanup:')));
    expect(source, isNot(contains('Failed to cleanup background worker:')));
  });

  test('unsafe executor cleanup reaches native quarantine without engine destruction', () {
    final dart = File('lib/domain/services/background_worker.service.dart').readAsStringSync();
    final swift = File('ios/Runner/Background/BackgroundWorker.swift').readAsStringSync();
    final kotlin = File(
      'android/app/src/main/kotlin/app/alextran/immich/background/BackgroundWorker.kt',
    ).readAsStringSync();

    expect(dart, contains('if (isUnsafeWorkerTermination(error)) rethrow;'));
    expect(swift, contains('where error.code == unsafeTerminationCode: self.quarantine()'));
    expect(swift, contains('if(isComplete || isQuarantined)'));
    expect(kotlin, contains('error.code == UNSAFE_TERMINATION_CODE'));
    expect(kotlin, contains('if (isQuarantined)'));
  });
}
