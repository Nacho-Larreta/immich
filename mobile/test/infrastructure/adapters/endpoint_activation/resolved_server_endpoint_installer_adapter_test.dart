import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/anonymous_server_discovery.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/resolved_server_endpoint_installer_adapter.dart';
import 'package:mocktail/mocktail.dart';

final class _MockApiGraph extends Mock implements EndpointApiGraphPort {}

final class _MockNativeContext extends Mock implements NativeRequestContextPort {}

final class _MockEndpointStore extends Mock implements ConfirmedEndpointStorePort {}

final class _PreparedGraph extends Fake implements PreparedApiGraph {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      NativeRequestContext(canonicalOrigin: null, accessToken: null, schemePolicy: null, customHeaders: const {}),
    );
    registerFallbackValue(
      ConfirmedServerEndpoint(
        apiEndpoint: Uri.parse('https://fallback.test/api'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
    );
  });

  test('installs the resolved endpoint with no previous server credentials', () async {
    final graph = _MockApiGraph();
    final nativeContext = _MockNativeContext();
    final endpointStore = _MockEndpointStore();
    final preparedGraph = _PreparedGraph();
    final endpoint = DiscoveredServerEndpoint(
      canonicalOrigin: Uri.parse('https://server-b.example.test'),
      apiEndpoint: Uri.parse('https://server-b.example.test/api'),
    );
    when(() => graph.currentEndpoint).thenReturn(Uri.parse('https://server-a.example.test/api'));
    when(nativeContext.snapshot).thenReturn(
      NativeRequestContext(
        canonicalOrigin: Uri.parse('https://server-a.example.test'),
        accessToken: 'server-a-token',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        customHeaders: const {'x-server': 'a'},
      ),
    );
    when(endpointStore.read).thenReturn(
      ConfirmedServerEndpoint(
        apiEndpoint: Uri.parse('https://server-a.example.test/api'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
    );
    when(() => graph.prepare(endpoint.apiEndpoint)).thenAnswer((_) async => preparedGraph);
    when(() => graph.prepare(Uri.parse('https://server-a.example.test/api'))).thenAnswer((_) async => _PreparedGraph());
    when(graph.block).thenReturn(null);
    when(nativeContext.block).thenReturn(null);
    when(() => nativeContext.replace(any())).thenAnswer((_) async {});
    when(() => graph.install(preparedGraph)).thenAnswer((_) async {});
    when(() => endpointStore.write(any())).thenAnswer((_) async {});
    var deviceHeaderInstallations = 0;
    final installer = ResolvedServerEndpointInstallerAdapter(
      mutex: SessionMutationMutex(),
      apiGraph: graph,
      nativeContext: nativeContext,
      endpointStore: endpointStore,
      installDeviceInfoHeaders: () async => deviceHeaderInstallations++,
    );

    await installer.installResolvedServerEndpoint(endpoint);

    final installedContext = verify(() => nativeContext.replace(captureAny())).captured.single as NativeRequestContext;
    expect(installedContext.canonicalOrigin, endpoint.canonicalOrigin);
    expect(installedContext.accessToken, isNull);
    expect(installedContext.customHeaders, isEmpty);
    verify(() => graph.install(preparedGraph)).called(1);
    final installedEndpoint =
        verify(() => endpointStore.write(captureAny())).captured.single as ConfirmedServerEndpoint;
    expect(installedEndpoint.apiEndpoint, endpoint.apiEndpoint);
    expect(installedEndpoint.schemePolicy, EndpointSchemePolicy.httpsOnly);
    verifyNever(() => nativeContext.snapshot());
    expect(deviceHeaderInstallations, 1);
  });

  for (final failedStep in _InstallationStep.values) {
    final testName = failedStep == _InstallationStep.deviceHeaders
        ? 'same-origin failure keeps native cleared despite persisted server A credentials'
        : 'restores server A when ${failedStep.name} fails';
    test(testName, () async {
      final fixture = _FaultInjectionFixture(failedStep);

      await expectLater(fixture.installer.installResolvedServerEndpoint(fixture.serverB), throwsA(isA<StateError>()));

      expect(fixture.graph.endpoint, fixture.serverA.apiEndpoint);
      expect(fixture.nativeContext.context.canonicalOrigin, isNull);
      expect(fixture.nativeContext.context.accessToken, isNull);
      expect(fixture.nativeContext.context.customHeaders, isEmpty);
      expect(fixture.nativeContext.persistedContext.accessToken, 'server-a-token');
      expect(fixture.nativeContext.persistedContext.customHeaders, {'x-server-a-key': 'secret'});
      expect(fixture.endpointStore.endpoint, fixture.serverA.apiEndpoint);
      expect(fixture.graph.blocked, isFalse);
      expect(fixture.nativeContext.blocked, isFalse);
      expect(fixture.nativeContext.snapshotCalls, 0);
    });
  }

  for (final rollbackFailure in _RollbackFailure.values) {
    test('remains fenced when rollback ${rollbackFailure.name} fails', () async {
      final fixture = _FaultInjectionFixture(_InstallationStep.endpointStore, rollbackFailure: rollbackFailure);

      await expectLater(
        fixture.installer.installResolvedServerEndpoint(fixture.serverB),
        throwsA(isA<ServerEndpointInstallationException>()),
      );

      expect(fixture.graph.blocked, isTrue);
      expect(fixture.nativeContext.blocked, isTrue);
    });
  }
}

enum _InstallationStep { nativeContext, apiGraph, endpointStore, deviceHeaders }

enum _RollbackFailure { graph, nativePurge, nativePublish }

final class _FaultInjectionFixture {
  _FaultInjectionFixture(this.failedStep, {_RollbackFailure? rollbackFailure})
    : graph = _FaultGraph(failedStep, rollbackFailure: rollbackFailure),
      nativeContext = _FaultNativeContext(failedStep, rollbackFailure: rollbackFailure),
      endpointStore = _FaultEndpointStore(failedStep) {
    installer = ResolvedServerEndpointInstallerAdapter(
      mutex: SessionMutationMutex(),
      apiGraph: graph,
      nativeContext: nativeContext,
      endpointStore: endpointStore,
      installDeviceInfoHeaders: () async {
        if (failedStep == _InstallationStep.deviceHeaders) {
          throw StateError('device headers failed');
        }
      },
    );
  }

  final _InstallationStep failedStep;
  final _FaultGraph graph;
  final _FaultNativeContext nativeContext;
  final _FaultEndpointStore endpointStore;
  late final ResolvedServerEndpointInstallerAdapter installer;
  final serverA = DiscoveredServerEndpoint(
    canonicalOrigin: Uri.parse('https://server-a.example.test'),
    apiEndpoint: Uri.parse('https://server-a.example.test/api'),
  );
  final serverB = DiscoveredServerEndpoint(
    canonicalOrigin: Uri.parse('https://server-a.example.test'),
    apiEndpoint: Uri.parse('https://server-a.example.test/immich/api'),
  );
}

final class _FaultPreparedGraph implements PreparedApiGraph {
  const _FaultPreparedGraph(this.endpoint);

  final Uri? endpoint;
}

final class _FaultGraph implements EndpointApiGraphPort {
  _FaultGraph(this.failedStep, {required this.rollbackFailure});

  final _InstallationStep failedStep;
  final _RollbackFailure? rollbackFailure;
  Uri? endpoint = Uri.parse('https://server-a.example.test/api');
  bool blocked = false;
  var installCalls = 0;

  @override
  Uri? get currentEndpoint => endpoint;

  @override
  void block() {
    blocked = true;
    endpoint = null;
  }

  @override
  Future<PreparedApiGraph> prepare(Uri apiEndpoint) async {
    return _FaultPreparedGraph(apiEndpoint.toString().isEmpty ? null : apiEndpoint);
  }

  @override
  Future<void> install(PreparedApiGraph graph) async {
    installCalls++;
    if ((failedStep == _InstallationStep.apiGraph && installCalls == 1) ||
        (rollbackFailure == _RollbackFailure.graph && installCalls > 1)) {
      throw StateError('graph install failed');
    }
    endpoint = (graph as _FaultPreparedGraph).endpoint;
    blocked = false;
  }
}

final class _FaultNativeContext implements NativeRequestContextPort {
  _FaultNativeContext(this.failedStep, {required this.rollbackFailure});

  final _InstallationStep failedStep;
  final _RollbackFailure? rollbackFailure;
  final persistedContext = NativeRequestContext(
    canonicalOrigin: Uri.parse('https://server-a.example.test'),
    accessToken: 'server-a-token',
    schemePolicy: EndpointSchemePolicy.httpsOnly,
    customHeaders: const {'x-server-a-key': 'secret'},
  );
  var context = NativeRequestContext(
    canonicalOrigin: null,
    accessToken: null,
    schemePolicy: null,
    customHeaders: const {},
  );
  bool blocked = false;
  var replaceCalls = 0;
  var snapshotCalls = 0;

  @override
  NativeRequestContext snapshot() {
    snapshotCalls++;
    return persistedContext;
  }

  @override
  void block() {
    blocked = true;
  }

  @override
  Future<void> replace(NativeRequestContext context) async {
    replaceCalls++;
    if (failedStep == _InstallationStep.nativeContext && replaceCalls == 1) {
      throw StateError('native context failed');
    }
    this.context = context;
    blocked = false;
  }

  @override
  Future<void> purge() async {
    if (rollbackFailure == _RollbackFailure.nativePurge) {
      throw StateError('native purge failed');
    }
    context = NativeRequestContext(
      canonicalOrigin: null,
      accessToken: null,
      schemePolicy: null,
      customHeaders: const {},
    );
  }

  @override
  void publishCleared() {
    if (rollbackFailure == _RollbackFailure.nativePublish) {
      throw StateError('native publish failed');
    }
    blocked = false;
  }
}

final class _FaultEndpointStore implements ConfirmedEndpointStorePort {
  _FaultEndpointStore(this.failedStep);

  final _InstallationStep failedStep;
  ConfirmedServerEndpoint? confirmedEndpoint = ConfirmedServerEndpoint(
    apiEndpoint: Uri.parse('https://server-a.example.test/api'),
    schemePolicy: EndpointSchemePolicy.httpsOnly,
  );
  Uri? get endpoint => confirmedEndpoint?.apiEndpoint;
  var writeCalls = 0;

  @override
  ConfirmedServerEndpoint? read() => confirmedEndpoint;

  @override
  Future<void> write(ConfirmedServerEndpoint? endpoint) async {
    writeCalls++;
    if (failedStep == _InstallationStep.endpointStore && writeCalls == 1) {
      throw StateError('endpoint store failed');
    }
    confirmedEndpoint = endpoint;
  }
}
