import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/infrastructure/adapters/connectivity/native_connectivity_monitor_adapter.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';

void main() {
  group('NativeConnectivityMonitorAdapter', () {
    for (final expectation in <(ConnectivityTransportAvailability, TransportAvailability)>[
      (ConnectivityTransportAvailability.unknown, TransportAvailability.unknown),
      (ConnectivityTransportAvailability.unavailable, TransportAvailability.unavailable),
      (ConnectivityTransportAvailability.available, TransportAvailability.available),
    ]) {
      test('maps initial ${expectation.$1.name} availability', () async {
        final harness = _Harness(snapshotAvailability: expectation.$1);

        final availability = await harness.adapter.initialAvailability;

        expect(availability, expectation.$2);
        expect(harness.registration.calls, [harness.adapter]);
        expect(harness.host.operations, ['start', 'getSnapshot']);
        await harness.adapter.dispose();
      });
    }

    test('maps native callbacks without interpreting available as server online', () async {
      final harness = _Harness();
      await harness.adapter.initialAvailability;
      final events = <TransportAvailability>[];
      final subscription = harness.adapter.events.listen(events.add);

      harness.registration.activeApi!.onTransportChanged(
        ConnectivityTransportSnapshot(
          availability: ConnectivityTransportAvailability.available,
          capabilities: const [],
        ),
      );
      harness.registration.activeApi!.onTransportChanged(
        ConnectivityTransportSnapshot(
          availability: ConnectivityTransportAvailability.unavailable,
          capabilities: const [],
        ),
      );

      expect(events, [TransportAvailability.available, TransportAvailability.unavailable]);
      await subscription.cancel();
      await harness.adapter.dispose();
    });

    test('preserves wifi, cellular, vpn, and unmetered capabilities', () async {
      final harness = _Harness(
        snapshotAvailability: ConnectivityTransportAvailability.available,
        snapshotCapabilities: const [
          ConnectivityNetworkCapability.wifi,
          ConnectivityNetworkCapability.cellular,
          ConnectivityNetworkCapability.vpn,
          ConnectivityNetworkCapability.unmetered,
        ],
      );

      final snapshot = await harness.adapter.initialSnapshot;

      expect(snapshot.available, isTrue);
      expect(snapshot.capabilities, {
        BackupNetworkCapability.wifi,
        BackupNetworkCapability.cellular,
        BackupNetworkCapability.vpn,
        BackupNetworkCapability.unmetered,
      });
      await harness.adapter.dispose();
    });

    test('shares one start then snapshot initialization', () async {
      final harness = _Harness();

      final first = harness.adapter.initialAvailability;
      final second = harness.adapter.initialAvailability;

      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      expect(harness.host.operations, ['start', 'getSnapshot']);
      expect(harness.registration.calls, [harness.adapter]);
      await harness.adapter.dispose();
    });

    test('maps a native start failure to unknown without requesting a snapshot', () async {
      final harness = _Harness(startError: const ConnectivityHostException('start failed'));

      expect(await harness.adapter.initialAvailability, TransportAvailability.unknown);
      expect(harness.host.operations, ['start']);
      await harness.adapter.dispose();
      expect(harness.host.disposeCount, 1);
    });

    test('maps an unexpected Pigeon channel failure to unknown', () async {
      final registration = _FakeConnectivityFlutterApiRegistration(null);
      final pigeonApi = _FailingConnectivityApi(StateError('channel failed'));
      final adapter = NativeConnectivityMonitorAdapter(
        api: PigeonConnectivityHostApi(api: pigeonApi),
        registerFlutterApi: registration.call,
      );

      expect(await adapter.initialAvailability, TransportAvailability.unknown);
      await adapter.dispose();
      expect(pigeonApi.disposeCount, 1);
    });

    test('maps Flutter API registration failure to unknown without starting native', () async {
      final harness = _Harness(registrationError: PlatformException(code: 'registration-failed'));

      expect(await harness.adapter.initialAvailability, TransportAvailability.unknown);
      expect(harness.host.operations, isEmpty);
      await harness.adapter.dispose();
      expect(harness.host.disposeCount, 1);
    });

    test('maps a native snapshot failure to unknown', () async {
      final harness = _Harness(snapshotError: const ConnectivityHostException('snapshot failed'));

      expect(await harness.adapter.initialAvailability, TransportAvailability.unknown);
      expect(harness.host.operations, ['start', 'getSnapshot']);
      await harness.adapter.dispose();
      expect(harness.host.disposeCount, 1);
    });

    test('invalidates a late callback and closes events before native dispose', () async {
      final harness = _Harness();
      await harness.adapter.initialAvailability;
      final registeredApi = harness.registration.activeApi!;
      final events = <TransportAvailability>[];
      final eventsDone = Completer<void>();
      harness.adapter.events.listen(events.add, onDone: eventsDone.complete);

      await harness.adapter.dispose();
      registeredApi.onTransportChanged(
        ConnectivityTransportSnapshot(
          availability: ConnectivityTransportAvailability.available,
          capabilities: const [],
        ),
      );

      await eventsDone.future;
      expect(events, isEmpty);
      expect(harness.registration.calls, [harness.adapter, null]);
      expect(harness.host.disposeCount, 1);
      expect(harness.host.stopCount, 0);
    });

    test('serializes exactly-once dispose behind a pending start', () async {
      final start = Completer<void>();
      final harness = _Harness(start: start.future);
      final initialization = harness.adapter.initialAvailability;
      await pumpEventQueue();

      final firstDispose = harness.adapter.dispose();
      final secondDispose = harness.adapter.dispose();
      await pumpEventQueue();

      expect(identical(firstDispose, secondDispose), isTrue);
      expect(harness.registration.activeApi, isNull);
      expect(harness.host.disposeCount, 0);
      start.complete();

      expect(await initialization, TransportAvailability.unknown);
      await Future.wait([firstDispose, secondDispose]);
      expect(harness.host.operations, ['start', 'dispose']);
      expect(harness.host.disposeCount, 1);
      expect(harness.host.stopCount, 0);
    });
  });
}

final class _Harness {
  _Harness({
    ConnectivityTransportAvailability snapshotAvailability = ConnectivityTransportAvailability.unknown,
    List<ConnectivityNetworkCapability> snapshotCapabilities = const [],
    Future<void>? start,
    Object? startError,
    Object? snapshotError,
    Object? registrationError,
  }) : host = _FakeConnectivityHostApi(
         snapshotAvailability: snapshotAvailability,
         snapshotCapabilities: snapshotCapabilities,
         start: start,
         startError: startError,
         snapshotError: snapshotError,
       ),
       registration = _FakeConnectivityFlutterApiRegistration(registrationError) {
    adapter = NativeConnectivityMonitorAdapter(api: host, registerFlutterApi: registration.call);
  }

  final _FakeConnectivityHostApi host;
  final _FakeConnectivityFlutterApiRegistration registration;
  late final NativeConnectivityMonitorAdapter adapter;
}

final class _FakeConnectivityFlutterApiRegistration {
  _FakeConnectivityFlutterApiRegistration(this.registrationError);

  final Object? registrationError;
  final List<ConnectivityFlutterApi?> calls = [];
  ConnectivityFlutterApi? activeApi;

  void call(ConnectivityFlutterApi? api) {
    calls.add(api);
    if (api != null) {
      final error = registrationError;
      if (error != null) {
        throw error;
      }
    }
    activeApi = api;
  }
}

final class _FakeConnectivityHostApi implements ConnectivityHostApi {
  _FakeConnectivityHostApi({
    required this.snapshotAvailability,
    required this.snapshotCapabilities,
    Future<void>? start,
    this.startError,
    this.snapshotError,
  }) : _start = start ?? Future.value();

  final ConnectivityTransportAvailability snapshotAvailability;
  final List<ConnectivityNetworkCapability> snapshotCapabilities;
  final Future<void> _start;
  final Object? startError;
  final Object? snapshotError;
  final List<String> operations = [];
  int disposeCount = 0;
  int stopCount = 0;

  @override
  Future<void> start() {
    operations.add('start');
    final error = startError;
    if (error != null) {
      return Future.error(error);
    }
    return _start;
  }

  @override
  Future<ConnectivityTransportSnapshot> getSnapshot() async {
    operations.add('getSnapshot');
    final error = snapshotError;
    if (error != null) {
      throw error;
    }
    return ConnectivityTransportSnapshot(availability: snapshotAvailability, capabilities: snapshotCapabilities);
  }

  @override
  Future<void> dispose() async {
    operations.add('dispose');
    disposeCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

final class _FailingConnectivityApi extends ConnectivityApi {
  _FailingConnectivityApi(this.error);

  final Object error;
  int disposeCount = 0;

  @override
  Future<void> start() => Future.error(error);

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}
