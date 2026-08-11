import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/worker_termination_safety.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  tearDown(() async {
    try {
      await workerManagerPatch.dispose();
    } on PlatformException catch (error) {
      if (!isUnsafeWorkerTermination(error)) rethrow;
    }
  });

  test('concurrent dispose closes admissions and terminal callbacks cannot repopulate workers', () async {
    await workerManagerPatch.init(isolatesCount: 1, dynamicSpawning: false);
    final events = <Object>[];
    final work = workerManagerPatch.executeWithPort<void, Object>(_slowExecutorTask, onMessage: events.add);
    final workFailure = expectLater(work, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');

    final first = workerManagerPatch.dispose();
    final second = workerManagerPatch.dispose();

    expect(() => workerManagerPatch.execute<void>(_emptyExecutorTask), throwsStateError);
    await Future.wait([first, second]);
    await workFailure;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(workerManagerPatch.pool, isEmpty);
    expect(workerManagerPatch.isDisposed, isTrue);
  });

  test('unsafe terminal quarantines its worker and replacement handles future work', () async {
    await workerManagerPatch.init(isolatesCount: 1, dynamicSpawning: false);
    final unsafeWorker = workerManagerPatch.pool.single;

    await expectLater(workerManagerPatch.execute<void>(_unsafeExecutorTask), throwsA(isA<PlatformException>()));
    await _waitForReplacement(unsafeWorker);

    expect(unsafeWorker.isTerminated, isFalse);
    expect(unsafeWorker.isReusable, isFalse);
    await workerManagerPatch.execute<void>(_emptyExecutorTask);
    await expectLater(
      workerManagerPatch.dispose(),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', unsafeWorkerTerminationCode)),
    );
  });

  test('dispose includes a quarantined worker previously removed by cancellation', () async {
    await workerManagerPatch.init(isolatesCount: 1, dynamicSpawning: false);
    final events = <Object>[];
    final retired = workerManagerPatch.pool.single;
    final work = workerManagerPatch.executeWithPort<void, Object>(_unsafeAfterCancellation, onMessage: events.add);
    final cancellation = expectLater(work, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');

    work.cancel();
    await cancellation;

    await expectLater(
      workerManagerPatch.dispose(),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', unsafeWorkerTerminationCode)),
    );
    expect(retired.isTerminated, isFalse);
    expect(retired.isReusable, isFalse);
  });
}

Future<void> _slowExecutorTask(SendPort port) async {
  port.send('started');
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

Future<void> _emptyExecutorTask() async {}

Future<void> _unsafeExecutorTask() async {
  throw PlatformException(code: unsafeWorkerTerminationCode);
}

Future<void> _unsafeAfterCancellation(SendPort port) async {
  port.send('started');
  await Future<void>.delayed(const Duration(milliseconds: 20));
  throw PlatformException(code: unsafeWorkerTerminationCode);
}

Future<void> _waitForReplacement(Object retired) async {
  while (workerManagerPatch.pool.isEmpty ||
      identical(workerManagerPatch.pool.single, retired) ||
      !workerManagerPatch.pool.single.isReusable) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _waitFor(List<Object> events, Object expected) async {
  while (!events.contains(expected)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
