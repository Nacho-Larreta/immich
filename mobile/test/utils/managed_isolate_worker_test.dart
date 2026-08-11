import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/managed_isolate_worker.dart';
import 'package:immich_mobile/utils/worker_termination_safety.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  test('dispose racing initialization terminates without leaking the spawned isolate', () async {
    final worker = ManagedIsolateWorker();

    final initialization = worker.initialize();
    final disposal = await worker.dispose();

    expect(disposal, WorkerDisposal.terminated);
    await initialization.timeout(const Duration(seconds: 1));
    expect(worker.isTerminated, isTrue);
    expect(worker.isReusable, isFalse);
  });

  test('gentle cancellation waits for computation finally before terminal', () async {
    final worker = ManagedIsolateWorker();
    await worker.initialize();
    final events = <Object>[];
    final finallySeen = Completer<void>();
    final task = TaskGentleWithPort<void>(
      id: 'gentle',
      workPriority: WorkPriority.immediately,
      execution: _gentleComputation,
      completer: Completer<void>(),
      onMessage: (event) {
        events.add(event);
        if (event == 'finally') finallySeen.complete();
      },
    );

    final terminal = worker.work(task);
    final terminalFailure = expectLater(terminal, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');
    worker.requestGentleCancellation();
    await _waitFor(events, 'cancel-seen');

    var terminalSeen = false;
    unawaited(terminal.then<void>((_) => terminalSeen = true, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(terminalSeen, isFalse);

    await finallySeen.future;
    await terminalFailure;
    expect(events, ['started', 'cancel-seen', 'finally']);
    await worker.dispose();
  });

  test('dispose timeout quarantines an active worker without killing or reuse', () async {
    final worker = ManagedIsolateWorker();
    await worker.initialize();
    final events = <Object>[];
    final task = TaskGentleWithPort<void>(
      id: 'slow',
      workPriority: WorkPriority.immediately,
      execution: _slowCancellationComputation,
      completer: Completer<void>(),
      onMessage: events.add,
    );

    final terminal = worker.work(task);
    final terminalFailure = expectLater(terminal, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');
    final disposal = await worker.dispose(drainTimeout: const Duration(milliseconds: 5));

    expect(disposal, WorkerDisposal.quarantined);
    expect(worker.isTerminated, isFalse);
    expect(worker.isReusable, isFalse);

    await terminalFailure;
    await worker.terminated;
    expect(worker.isTerminated, isTrue);
  });

  test('regular work is not killed before its finally block reaches terminal', () async {
    final worker = ManagedIsolateWorker();
    await worker.initialize();
    final events = <Object>[];
    final task = TaskWithPort<void>(
      id: 'regular',
      workPriority: WorkPriority.immediately,
      execution: _regularComputation,
      completer: Completer<void>(),
      onMessage: events.add,
    );

    final terminal = worker.work(task);
    final terminalFailure = expectLater(terminal, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');

    final disposal = await worker.dispose(drainTimeout: const Duration(milliseconds: 5));
    expect(disposal, WorkerDisposal.quarantined);
    expect(worker.isTerminated, isFalse);

    await terminalFailure;
    expect(events, containsAllInOrder(['started', 'finally']));
    await worker.terminated;
  });

  test('unsafe drain failure quarantines without kill or reuse', () async {
    final worker = ManagedIsolateWorker();
    await worker.initialize();
    final task = TaskRegular<void>(
      id: 'unsafe-drain',
      workPriority: WorkPriority.immediately,
      execution: _unsafeDrainFailure,
      completer: Completer<void>(),
    );

    await expectLater(worker.work(task), throwsA(isA<PlatformException>()));
    final disposal = await worker.dispose();

    expect(disposal, WorkerDisposal.quarantined);
    expect(worker.isTerminated, isFalse);
    expect(worker.isReusable, isFalse);
  });

  test('hanging drain timeout quarantines until a safe terminal arrives', () async {
    final worker = ManagedIsolateWorker();
    await worker.initialize();
    final events = <Object>[];
    final task = TaskWithPort<void>(
      id: 'hanging-drain',
      workPriority: WorkPriority.immediately,
      execution: _hangingDrain,
      completer: Completer<void>(),
      onMessage: events.add,
    );

    final terminal = worker.work(task);
    final terminalFailure = expectLater(terminal, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');
    final disposal = await worker.dispose(drainTimeout: const Duration(milliseconds: 5));

    expect(disposal, WorkerDisposal.quarantined);
    expect(worker.isTerminated, isFalse);
    expect(worker.isReusable, isFalse);
    await terminalFailure;
    await worker.terminated;
  });
}

Future<void> _gentleComputation(SendPort port, bool Function() cancelled) async {
  port.send('started');
  while (!cancelled()) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  port.send('cancel-seen');
  try {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  } finally {
    port.send('finally');
  }
}

Future<void> _slowCancellationComputation(SendPort port, bool Function() cancelled) async {
  port.send('started');
  while (!cancelled()) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  await Future<void>.delayed(const Duration(milliseconds: 40));
}

Future<void> _regularComputation(SendPort port) async {
  port.send('started');
  try {
    await Future<void>.delayed(const Duration(milliseconds: 35));
  } finally {
    port.send('finally');
  }
}

Future<void> _unsafeDrainFailure() async {
  throw PlatformException(code: unsafeWorkerTerminationCode);
}

Future<void> _hangingDrain(SendPort port) async {
  port.send('started');
  await Future<void>.delayed(const Duration(milliseconds: 40));
}

Future<void> _waitFor(List<Object> events, Object expected) async {
  while (!events.contains(expected)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
