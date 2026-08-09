import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_activation.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/interfaces/reconciliation.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/interfaces/temporary_files.interface.dart';
import 'package:immich_mobile/domain/interfaces/transport_events.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

void main() {
  test('transport events remain cancelable through their stream subscription', () async {
    final controller = StreamController<TransportAvailability>();
    final port = _TransportEventsPort(controller.stream);
    final received = <TransportAvailability>[];
    final subscription = port.events.listen(received.add);

    expect(await port.initialAvailability, TransportAvailability.unavailable);
    controller.add(TransportAvailability.available);
    await pumpEventQueue();
    await subscription.cancel();
    controller.add(TransportAvailability.unavailable);
    await pumpEventQueue();

    expect(received, [TransportAvailability.available]);
    await controller.close();
  });

  test('all effectful ports return a cancellable request', () {
    final operation = _CompletedRequest<OfflineResult<String>>(const OfflineResult.success('ok'));
    final probePort = _EndpointProbePort(operation);
    final activationPort = _EndpointActivationPort(operation);
    final reconciliationPort = _ReconciliationPort(operation);
    final localMediaPort = _LocalMediaPort(operation);
    final remoteMediaPort = _RemoteMediaPort(operation);
    final temporaryFilesPort = _TemporaryFilesPort(operation);

    expect(probePort.operation, isA<CancellableRequest<OfflineResult<String>>>());
    expect(activationPort.operation, isA<CancellableRequest<OfflineResult<String>>>());
    expect(reconciliationPort.operation, isA<CancellableRequest<OfflineResult<String>>>());
    expect(localMediaPort.operation, isA<CancellableRequest<OfflineResult<String>>>());
    expect(remoteMediaPort.operation, isA<CancellableRequest<OfflineResult<String>>>());
    expect(temporaryFilesPort.operation, isA<CancellableRequest<OfflineResult<String>>>());
  });
}

final class _CompletedRequest<T> implements CancellableRequest<T> {
  _CompletedRequest(this._value);

  final T _value;

  @override
  Future<T> get result => Future.value(_value);

  @override
  Future<void> cancel() async {}
}

final class _TransportEventsPort implements TransportEventsPort {
  _TransportEventsPort(this.events);

  @override
  final Stream<TransportAvailability> events;

  @override
  Future<TransportAvailability> get initialAvailability => Future.value(TransportAvailability.unavailable);
}

final class _EndpointProbePort implements EndpointProbePort {
  _EndpointProbePort(this.operation);

  final CancellableRequest<OfflineResult<String>> operation;

  @override
  CancellableRequest<EndpointProbeResult> probe(EndpointProbeRequest request) {
    throw UnimplementedError();
  }
}

final class _EndpointActivationPort implements EndpointActivationPort {
  _EndpointActivationPort(this.operation);

  final CancellableRequest<OfflineResult<String>> operation;

  @override
  CancellableRequest<OfflineResult<EndpointActivationReceipt>> activate(EndpointActivationRequest request) {
    throw UnimplementedError();
  }
}

final class _ReconciliationPort implements ReconciliationPort {
  _ReconciliationPort(this.operation);

  final CancellableRequest<OfflineResult<String>> operation;

  @override
  CancellableRequest<OfflineResult<OperationCompletion>> reconcile(ReconciliationRequest request) {
    throw UnimplementedError();
  }
}

final class _LocalMediaPort implements LocalMediaPort<String> {
  _LocalMediaPort(this.operation);

  final CancellableRequest<OfflineResult<String>> operation;

  @override
  CancellableMediaRequest<String> request(LocalMediaRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> cancelAll() async {}
}

final class _RemoteMediaPort implements RemoteMediaPort<String> {
  _RemoteMediaPort(this.operation);

  final CancellableRequest<OfflineResult<String>> operation;

  @override
  CancellableMediaRequest<String> request(RemoteMediaRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> cancelAll() async {}
}

final class _TemporaryFilesPort implements TemporaryFilesPort<String> {
  _TemporaryFilesPort(this.operation);

  final CancellableRequest<OfflineResult<String>> operation;

  @override
  CancellableRequest<OfflineResult<String>> write(TemporaryFileWriteRequest request) => operation;

  @override
  CancellableRequest<OfflineResult<OperationCompletion>> delete(String temporaryFile) {
    throw UnimplementedError();
  }
}
