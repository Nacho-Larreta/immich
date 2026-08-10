import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/timeline_source_preference.interface.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_source_filter.provider.dart';

void main() {
  test('defaults to device without a configured server', () {
    final container = _container(phase: RemoteAuthenticationPhase.unconfigured);
    addTearDown(container.dispose);

    final selection = container.read(timelineSourceSelectionProvider);
    expect(selection.explicitSource, isNull);
    expect(selection.effectiveSource, TimelineSourceFilter.device);
  });

  test('defaults to combined with a configured server and fails safe on corrupt preference', () {
    final container = _container(
      phase: RemoteAuthenticationPhase.reauthenticationRequired,
      preference: _FakePreference(999),
    );
    addTearDown(container.dispose);

    final selection = container.read(timelineSourceSelectionProvider);
    expect(selection.explicitSource, isNull);
    expect(selection.effectiveSource, TimelineSourceFilter.combined);
  });

  test('persists explicit selection and forget server does not erase user intent', () async {
    final preference = _FakePreference(null);
    final container = _container(phase: RemoteAuthenticationPhase.authenticated, preference: preference);
    addTearDown(container.dispose);

    await container.read(timelineSourceSelectionProvider.notifier).select(TimelineSourceFilter.server);
    expect(preference.rawValue, TimelineSourceFilter.server.index);
    expect(container.read(timelineSourceSelectionProvider).effectiveSource, TimelineSourceFilter.server);

    container.read(remoteAuthenticationPhaseProvider.notifier).state = RemoteAuthenticationPhase.unconfigured;
    expect(container.read(timelineSourceSelectionProvider).explicitSource, TimelineSourceFilter.server);
    expect(container.read(timelineSourceSelectionProvider).effectiveSource, TimelineSourceFilter.device);

    container.read(remoteAuthenticationPhaseProvider.notifier).state = RemoteAuthenticationPhase.authenticated;
    expect(container.read(timelineSourceSelectionProvider).effectiveSource, TimelineSourceFilter.server);
  });

  test('restores every explicit source after recreating the provider container', () async {
    for (final source in TimelineSourceFilter.values) {
      final preference = _FakePreference(null);
      final first = _container(phase: RemoteAuthenticationPhase.authenticated, preference: preference);
      await first.read(timelineSourceSelectionProvider.notifier).select(source);
      first.dispose();

      final recreated = _container(phase: RemoteAuthenticationPhase.authenticated, preference: preference);
      expect(recreated.read(timelineSourceSelectionProvider).explicitSource, source);
      expect(recreated.read(timelineSourceSelectionProvider).effectiveSource, source);
      recreated.dispose();
    }
  });

  test('rolls back optimistic selection when persistence fails', () async {
    final container = _container(
      phase: RemoteAuthenticationPhase.authenticated,
      preference: _ThrowingPreference(TimelineSourceFilter.device.index),
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(timelineSourceSelectionProvider.notifier).select(TimelineSourceFilter.server),
      throwsStateError,
    );
    expect(container.read(timelineSourceSelectionProvider).explicitSource, TimelineSourceFilter.device);
    expect(container.read(timelineSourceSelectionProvider).effectiveSource, TimelineSourceFilter.device);
  });

  test('offline and probing never mutate the explicit source', () async {
    final preference = _FakePreference(TimelineSourceFilter.server.index);
    final container = _container(phase: RemoteAuthenticationPhase.authenticated, preference: preference);
    addTearDown(container.dispose);

    for (final phase in [ReachabilityPhase.probing, ReachabilityPhase.offline]) {
      container.read(serverReachabilityStateProvider.notifier).state = ReachabilityState(
        phase: phase,
        sessionEpoch: 1,
        probeGeneration: 1,
      );
      expect(container.read(timelineSourceSelectionProvider).effectiveSource, TimelineSourceFilter.server);
      expect(preference.rawValue, TimelineSourceFilter.server.index);
    }
  });
}

ProviderContainer _container({required RemoteAuthenticationPhase phase, TimelineSourcePreferencePort? preference}) =>
    ProviderContainer(
      overrides: [
        timelineSourcePreferenceProvider.overrideWithValue(preference ?? _FakePreference(null)),
        remoteAuthenticationPhaseProvider.overrideWith((_) => phase),
      ],
    );

final class _FakePreference implements TimelineSourcePreferencePort {
  _FakePreference(this.rawValue);

  int? rawValue;

  @override
  int? readRaw() => rawValue;

  @override
  Future<void> write(TimelineSourceFilter source) async {
    rawValue = source.index;
  }
}

final class _ThrowingPreference implements TimelineSourcePreferencePort {
  _ThrowingPreference(this.rawValue);

  final int? rawValue;

  @override
  int? readRaw() => rawValue;

  @override
  Future<void> write(TimelineSourceFilter source) => throw StateError('write failed');
}
