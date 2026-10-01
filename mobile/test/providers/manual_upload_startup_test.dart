import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_authority.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_outbox.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_source.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_staging.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_transport.interface.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_transport.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/providers/manual_upload.provider.dart';
import 'package:immich_mobile/providers/manual_upload_owner_drain.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  test('attached worker startup cannot instantiate the manual coordinator or outbox', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    NetworkRepository.setContextRoleForTest(NetworkContextRole.attachedWorker);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      NetworkRepository.setContextRoleForTest(NetworkContextRole.rootWriter);
    });
    var outboxCreations = 0;
    final container = ProviderContainer(
      overrides: [
        manualUploadOutboxProvider.overrideWith((_) {
          outboxCreations++;
          throw StateError('Worker must not create a manual outbox');
        }),
      ],
    );
    addTearDown(container.dispose);

    container.read(manualUploadStartupProvider);

    expect(outboxCreations, 0);
    expect(() => container.read(manualUploadCoordinatorProvider), throwsStateError);
    expect(outboxCreations, 0);
  });

  test('resource shutdown waits for every previous owner and stops each exactly once', () async {
    final drain = ManualUploadOwnerDrain();
    final oldOwner = Completer<void>();
    final newOwner = Completer<void>();
    var oldStops = 0;
    var newStops = 0;
    final stopOld = drain.register(() {
      oldStops++;
      return oldOwner.future;
    });
    drain.register(() {
      newStops++;
      return newOwner.future;
    });
    final stoppingOld = stopOld();
    var released = false;
    final release = drain.drain().then((_) => released = true);
    final repeated = drain.drain();
    oldOwner.complete();
    await stoppingOld;
    expect(released, isFalse);
    newOwner.complete();
    await Future.wait([release, repeated]);
    expect(released, isTrue);
    expect(oldStops, 1);
    expect(newStops, 1);
  });

  test('root cold start restores queue once and resume replays without replacing its owner', () async {
    final outbox = _Outbox();
    final transport = _Transport();
    final container = _container(outbox, transport);
    addTearDown(() async {
      container.dispose();
      await outbox.controller.close();
      await transport.controller.close();
    });

    container.read(manualUploadStartupProvider);
    final owner = container.read(manualUploadCoordinatorProvider);
    await Future<void>.delayed(Duration.zero);
    expect(transport.replays, 1);
    expect(outbox.reads, 1);
    expect(outbox.subscriptions, 1);
    expect(transport.subscriptions, 1);

    container.invalidate(manualUploadStartupProvider);
    container.read(manualUploadStartupProvider);
    expect(identical(container.read(manualUploadCoordinatorProvider), owner), isTrue);
    expect(outbox.subscriptions, 1);
    expect(transport.subscriptions, 1);
    container.read(manualUploadResumeSignalProvider).add(null);
    await Future<void>.delayed(Duration.zero);
    expect(transport.replays, 2);
    expect(outbox.reads, 2);
  });

  test('restored authorized connectivity pumps pending manual work without automatic backup enablement', () async {
    final outbox = _Outbox();
    final transport = _Transport();
    final container = _container(outbox, transport);
    addTearDown(() async {
      container.dispose();
      await outbox.controller.close();
      await transport.controller.close();
    });
    container.read(manualUploadStartupProvider);
    await Future<void>.delayed(Duration.zero);
    final before = outbox.reads;
    final endpoint = Uri.parse('https://photos.test/api');
    container.read(serverReachabilityStateProvider.notifier).state = ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 1,
      probeGeneration: 1,
      confirmedEndpoint: endpoint,
      serverAccess: ConfirmedServerAccess(
        apiEndpoint: endpoint,
        canonicalOrigin: Uri.parse(endpoint.origin),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        nativeContextGeneration: 1,
        confirmed: true,
        fenced: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(outbox.reads, before + 1);
    expect(transport.replays, 1);
  });
}

ProviderContainer _container(_Outbox outbox, _Transport transport) => ProviderContainer(
  overrides: [
    manualUploadRootEnabledProvider.overrideWithValue(true),
    manualUploadOutboxProvider.overrideWithValue(outbox),
    manualUploadTransportProvider.overrideWithValue(transport),
    manualUploadStagingProvider.overrideWithValue(_Staging()),
    manualUploadSourceProvider.overrideWithValue(_Source()),
    manualUploadAuthorityProvider.overrideWithValue(_Authority()),
    manualUploadLifetimeProvider.overrideWithValue(_Lifetime()),
    manualUploadConfirmedProjectionProvider.overrideWithValue((_) async {}),
  ],
);

class _Staging extends Mock implements ManualUploadStagingPort {}

class _Source extends Mock implements ManualUploadSourcePort {}

class _Lifetime extends Mock implements BackupOperationLifetimePort {}

class _Authority implements ManualUploadAuthoritySourcePort {
  @override
  ManualUploadDestination? currentDestination() =>
      const ManualUploadDestination(serverUrl: 'https://photos.test', userId: 'user');
  @override
  ManualUploadAuthority? captureAuthorized() => null;
}

class _Outbox implements ManualUploadOutbox {
  final controller = StreamController<void>.broadcast();
  int reads = 0;
  int subscriptions = 0;
  @override
  Stream<void> get changes {
    subscriptions++;
    return controller.stream;
  }

  @override
  Future<List<ManualUploadIntent>> listActive(
    ManualUploadDestination destination, {
    int limit = 100,
    String? afterId,
  }) async {
    reads++;
    return [];
  }

  @override
  Future<ManualUploadIntent?> read(String intentId) async => null;
  @override
  Future<bool> compareAndSet(ManualUploadIntent expected, ManualUploadIntent next) async => false;
  @override
  Future<List<ManualUploadIntent>> submit(List<ManualUploadSelection> selections) async => [];
}

class _Transport implements ManualUploadTransportPort {
  final controller = StreamController<ManualUploadNativeEvent>.broadcast();
  int replays = 0;
  int subscriptions = 0;
  @override
  Stream<ManualUploadNativeEvent> get events {
    subscriptions++;
    return controller.stream;
  }

  @override
  Future<void> replayUndeliveredUpdates() async => replays++;
  @override
  Future<bool> enqueue(ManualUploadEnqueueRequest request) async => false;
  @override
  Future<ManualUploadObservation> observe(ManualUploadIntent intent) async =>
      const ManualUploadObservation(ManualUploadObservationState.unknown);
  @override
  Future<bool> cancelAndDrain(ManualUploadIntent intent) async => false;
  @override
  void forgetAttempt(ManualUploadAttempt attempt) {}
  @override
  void dispose() {}
}
