import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/interfaces/request_context_lease.interface.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/registered_local_http_lease_adapter.dart';

void main() {
  group('EndpointActivationAdapter', () {
    test('rejects stale generation and wrong user without side effects', () async {
      final harness = _Harness();

      final stale = await harness.adapter.activate(harness.request(probeGeneration: 8)).result;
      final wrongUser = await harness.adapter.activate(harness.request(userId: 'another-user')).result;

      expect(stale, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled));
      expect(wrongUser, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.wrongServer));
      expect(harness.events, isEmpty);
    });

    test('uses the exact API subpath and only the canonical origin for native auth', () async {
      final harness = _Harness();

      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, isA<OfflineSuccess<EndpointActivationReceipt>>());
      expect(harness.graph.currentEndpoint, Uri.parse('https://photos.test/family/api'));
      expect(harness.native.current.canonicalOrigin, Uri.parse('https://photos.test'));
      expect(harness.native.current.canonicalOrigin?.path, isEmpty);
      expect(harness.native.current.accessToken, 'current-token');
      expect(harness.widget.current.apiEndpoint, Uri.parse('https://photos.test/family/api'));
      expect(harness.widget.current.customHeaders, '{"X-First":"one","X-Second":"two"}');
    });

    test('serializes concurrent activations with the shared mutex', () async {
      final gate = Completer<void>();
      final firstEntered = Completer<void>();
      var nativeCalls = 0;
      final harness = _Harness(
        checkpoint: (step) async {
          if (step == EndpointActivationStep.nativeContext && ++nativeCalls == 1) {
            firstEntered.complete();
            await gate.future;
          }
        },
      );

      final first = harness.adapter.activate(harness.request());
      await firstEntered.future;
      final second = harness.adapter.activate(harness.request());
      await Future<void>.delayed(Duration.zero);

      expect(nativeCalls, 1);
      gate.complete();
      expect(await first.result, isA<OfflineSuccess<EndpointActivationReceipt>>());
      expect(await second.result, isA<OfflineSuccess<EndpointActivationReceipt>>());
      expect(nativeCalls, 2);
    });

    test('stale local HTTP replace is fenced and purged before any activation is published', () async {
      final replaceGate = Completer<void>();
      final harness = _Harness(
        replaceGate: replaceGate,
        leaseBuilder: (native) => RegisteredLocalHttpLeaseAdapter(
          readActivePolicy: () => null,
          blockRequests: native.block,
          purgeRequestContext: native.purge,
        ),
      );
      final operation = harness.adapter.activate(
        harness.request(schemePolicy: EndpointSchemePolicy.registeredLocalHttp),
      );
      await harness.native.replaceStarted.future;

      expect(harness.lease.invalidateForTransportReview(), isTrue);
      expect(harness.native.blocked, isTrue);
      replaceGate.complete();

      expect(
        await operation.result,
        const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled),
      );
      expect(harness.native.blockCalls, greaterThanOrEqualTo(2));
      expect(harness.native.purgeCalls, greaterThanOrEqualTo(2));
      expect(harness.native.current.accessToken, isNull);
      expect(harness.graph.currentEndpoint, Uri.parse('https://old.test/api'));
      expect(harness.store.current.apiEndpoint, Uri.parse('https://old.test/api'));
      expect(harness.widget.current.accessToken, 'old-token');

      final fresh = await harness.adapter
          .activate(harness.request(schemePolicy: EndpointSchemePolicy.registeredLocalHttp))
          .result;
      expect(fresh, isA<OfflineSuccess<EndpointActivationReceipt>>());
    });

    test('transport change after local HTTP commit purges instead of restoring the previous context', () async {
      late _Harness harness;
      harness = _Harness(
        checkpoint: (step) async {
          if (step == EndpointActivationStep.nativeContext) {
            expect(harness.lease.invalidateForTransportReview(), isTrue);
            throw StateError('transport changed after native commit');
          }
        },
        leaseBuilder: (native) => RegisteredLocalHttpLeaseAdapter(
          readActivePolicy: () => EndpointSchemePolicy.registeredLocalHttp,
          blockRequests: native.block,
          purgeRequestContext: native.purge,
        ),
      );

      final result = await harness.adapter
          .activate(harness.request(schemePolicy: EndpointSchemePolicy.registeredLocalHttp))
          .result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.serverUnavailable));
      expect(harness.native.current.accessToken, isNull);
      expect(harness.widget.current.accessToken, isNull);
      expect(harness.graph.currentEndpoint, Uri());
      expect(harness.rollbackEvents, isNot(contains('native.replace')));
      expect(harness.rollbackEvents, containsAll(['native.clear', 'widget.clear', 'graph.prepare', 'graph.install']));
    });

    for (final failedStep in EndpointActivationStep.values) {
      test('rolls back in reverse order after ${failedStep.name}', () async {
        final harness = _Harness(
          checkpoint: (step) async {
            if (step == failedStep) {
              throw StateError('injected after ${step.name}');
            }
          },
        );

        final result = await harness.adapter.activate(harness.request()).result;

        expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.serverUnavailable));
        expect(harness.rollbackEvents, _expectedRollback(failedStep));
        expect(harness.native.current.canonicalOrigin, Uri.parse('https://old.test'));
        expect(harness.graph.currentEndpoint, Uri.parse('https://old.test/api'));
        expect(harness.store.current.apiEndpoint, Uri.parse('https://old.test/api'));
        expect(harness.widget.current.accessToken, 'old-token');
        if (failedStep.index >= EndpointActivationStep.apiGraph.index) {
          expect(harness.graph.installedGraphs.last, isNot(same(harness.graph.initialGraph)));
        }
      });
    }

    test('continues rollback when a compensation fails', () async {
      final harness = _Harness(
        checkpoint: (step) async {
          if (step == EndpointActivationStep.widgetCredentials) throw StateError('widget checkpoint');
        },
      );
      harness.widget.failNextWriteAfterActivation = true;

      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.serverUnavailable));
      expect(
        harness.rollbackEvents,
        containsAllInOrder(['widget.write', 'store.write', 'native.replace', 'graph.prepare', 'graph.install']),
      );
      expect(harness.native.current.canonicalOrigin, Uri.parse('https://old.test'));
      expect(harness.graph.installedGraphs.last.clientIdentity, harness.native.clientIdentity);
    });

    test('compensates a collaborator that mutates and then throws', () async {
      final harness = _Harness();
      harness.native.failAfterMutation = true;

      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.serverUnavailable));
      expect(harness.rollbackEvents, ['native.replace']);
      expect(harness.native.current.canonicalOrigin, Uri.parse('https://old.test'));
      expect(harness.native.current.accessToken, 'old-token');
    });

    test('does not resurrect token when the session epoch changes during activation', () async {
      late _Harness harness;
      harness = _Harness(
        checkpoint: (step) async {
          if (step == EndpointActivationStep.nativeContext) {
            harness.session.current = harness.session.current.copyWith(sessionEpoch: 4);
          }
        },
      );

      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled));
      expect(harness.native.current.accessToken, isNull);
      expect(harness.rollbackEvents, containsAll(['native.clear', 'widget.clear', 'graph.prepare', 'graph.install']));
    });

    test('installs an empty fresh graph when logout races after graph installation', () async {
      late _Harness harness;
      harness = _Harness(
        checkpoint: (step) async {
          if (step == EndpointActivationStep.apiGraph) {
            harness.session.current = harness.session.current.copyWith(sessionEpoch: 4);
          }
        },
      );

      final activatedGraph = harness.graph.installedGraphs.length;
      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled));
      expect(harness.graph.currentEndpoint, Uri());
      expect(harness.graph.installedGraphs.length, activatedGraph + 3);
      expect(harness.graph.installedGraphs.last, isNot(same(harness.graph.initialGraph)));
      expect(harness.native.current.accessToken, isNull);
      expect(harness.rollbackEvents, containsAll(['native.clear', 'widget.clear', 'graph.prepare', 'graph.install']));
    });

    test('purges every credential surface when epoch changes before the first side effect', () async {
      late _Harness harness;
      harness = _Harness(
        beforePrepare: () {
          harness.session.current = harness.session.current.copyWith(sessionEpoch: 4);
        },
      );

      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled));
      expect(harness.native.current.accessToken, isNull);
      expect(harness.widget.current.accessToken, isNull);
      expect(harness.graph.currentEndpoint, Uri());
      expect(harness.graph.installedGraphs.last.clientIdentity, harness.native.clientIdentity);
      expect(harness.rollbackEvents, containsAll(['native.clear', 'widget.clear', 'graph.prepare', 'graph.install']));
    });

    test('does not retry a failed non-cancellable purge', () async {
      late _Harness harness;
      harness = _Harness(
        checkpoint: (step) async {
          if (step == EndpointActivationStep.widgetCredentials) {
            harness.session.current = harness.session.current.copyWith(sessionEpoch: 4);
          }
        },
      );
      harness.native.clearFailuresRemaining = 1;

      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.credentialPurgeFailed));
      expect(harness.rollbackEvents.where((event) => event == 'native.clear'), hasLength(1));
      expect(harness.graph.blocked, isTrue);
      expect(harness.native.blocked, isTrue);
    });

    test('returns credentialPurgeFailed and keeps fences when stale purge fails', () async {
      late _Harness harness;
      harness = _Harness(
        checkpoint: (step) async {
          if (step == EndpointActivationStep.widgetCredentials) {
            harness.session.current = harness.session.current.copyWith(sessionEpoch: 4);
          }
        },
      );
      harness.widget.clearFailuresRemaining = 1;

      final result = await harness.adapter.activate(harness.request()).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.credentialPurgeFailed));
      expect(harness.rollbackEvents.where((event) => event == 'widget.clear'), hasLength(1));
      expect(harness.graph.blocked, isTrue);
      expect(harness.native.blocked, isTrue);
    });

    test('times out a hanging purge once and preserves every fence', () async {
      late _Harness harness;
      harness = _Harness(
        stalePurgeAttemptTimeout: const Duration(milliseconds: 5),
        beforePrepare: () {
          harness.session.current = harness.session.current.copyWith(sessionEpoch: 4);
        },
      );
      harness.widget.hangOnClear = true;

      final result = await harness.adapter.activate(harness.request()).result.timeout(const Duration(seconds: 1));

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.credentialPurgeFailed));
      expect(harness.rollbackEvents.where((event) => event == 'widget.clear'), hasLength(1));
      expect(harness.native.current.accessToken, isNull);
      expect(harness.graph.currentEndpoint, Uri());
      expect(harness.graph.blocked, isTrue);
      expect(harness.native.blocked, isTrue);
    });

    test('blocks graph and native requests while stale purge is pending', () async {
      late _Harness harness;
      final clearGate = Completer<void>();
      harness = _Harness(
        beforePrepare: () {
          harness.session.current = harness.session.current.copyWith(sessionEpoch: 4);
        },
      );
      harness.widget.clearGate = clearGate;

      final operation = harness.adapter.activate(harness.request());
      await harness.widget.clearStarted.future;

      expect(harness.graph.blocked, isTrue);
      expect(harness.graph.currentEndpoint, Uri());
      expect(harness.native.blocked, isTrue);

      clearGate.complete();
      expect(
        await operation.result,
        const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled),
      );
      expect(harness.graph.installedGraphs.last.clientIdentity, harness.native.clientIdentity);
      expect(harness.native.blocked, isFalse);
    });
  });
}

List<String> _expectedRollback(EndpointActivationStep step) => switch (step) {
  EndpointActivationStep.nativeContext => ['native.replace'],
  EndpointActivationStep.apiGraph => ['native.replace', 'graph.prepare', 'graph.install'],
  EndpointActivationStep.endpointStore => ['store.write', 'native.replace', 'graph.prepare', 'graph.install'],
  EndpointActivationStep.widgetCredentials => [
    'widget.write',
    'store.write',
    'native.replace',
    'graph.prepare',
    'graph.install',
  ],
};

final class _Harness {
  _Harness({
    EndpointActivationCheckpoint? checkpoint,
    FutureOr<void> Function()? beforePrepare,
    Completer<void>? replaceGate,
    RequestContextLeasePort Function(_Native native)? leaseBuilder,
    Duration stalePurgeAttemptTimeout = const Duration(seconds: 5),
  }) {
    graph.currentClientIdentity = () => native.clientIdentity;
    graph.beforePrepare = beforePrepare;
    native.replaceGate = replaceGate;
    lease = leaseBuilder?.call(native) ?? _Lease();
    adapter = EndpointActivationAdapter(
      mutex: SessionMutationMutex(),
      session: session,
      apiGraph: graph,
      nativeContext: native,
      requestContextLease: lease,
      endpointStore: store,
      widgetCredentials: widget,
      checkpoint: checkpoint,
      stalePurgeAttemptTimeout: stalePurgeAttemptTimeout,
    );
  }

  final events = <String>[];
  late final session = _Session();
  late final graph = _Graph(events);
  late final native = _Native(events);
  late final RequestContextLeasePort lease;
  late final store = _Store(events);
  late final widget = _Widget(events);
  late final EndpointActivationAdapter adapter;

  List<String> get rollbackEvents {
    final firstRollback = events.indexWhere((event) => event.endsWith('.rollback'));
    if (firstRollback < 0) return const [];
    return events.skip(firstRollback).map((event) => event.replaceAll('.rollback', '')).toList();
  }

  EndpointActivationRequest request({
    int probeGeneration = 7,
    String userId = 'cached-user',
    EndpointSchemePolicy schemePolicy = EndpointSchemePolicy.httpsOnly,
  }) {
    final canonicalOrigin = schemePolicy == EndpointSchemePolicy.httpsOnly
        ? Uri.parse('https://photos.test')
        : Uri.parse('http://photos.test');
    return EndpointActivationRequest(
      endpoint: ValidatedEndpointProbeResult(
        canonicalOrigin: canonicalOrigin,
        apiEndpoint: canonicalOrigin.replace(path: '/family/api'),
        userId: userId,
        schemePolicy: schemePolicy,
      ),
      sessionEpoch: 3,
      probeGeneration: probeGeneration,
    );
  }
}

final class _Lease implements RequestContextLeasePort {
  RequestContextActivationLease? pending;
  var revision = 0;

  @override
  RequestContextActivationLease? beginActivation(EndpointSchemePolicy policy) {
    if (policy != EndpointSchemePolicy.registeredLocalHttp) return null;
    return pending = RequestContextActivationLease(revision);
  }

  @override
  bool commitActivation(RequestContextActivationLease lease) {
    if (!identical(pending, lease)) return false;
    pending = null;
    return lease.transportRevision == revision;
  }

  @override
  bool isCurrent(RequestContextActivationLease lease) => lease.transportRevision == revision;

  @override
  void abandonActivation(RequestContextActivationLease lease) {
    if (identical(pending, lease)) pending = null;
  }

  @override
  bool invalidateForTransportReview() {
    revision++;
    return pending != null;
  }

  @override
  void invalidateAfterValidationFailure() {
    revision++;
  }
}

extension on ActivationSessionSnapshot {
  ActivationSessionSnapshot copyWith({int? sessionEpoch}) => ActivationSessionSnapshot(
    sessionEpoch: sessionEpoch ?? this.sessionEpoch,
    probeGeneration: probeGeneration,
    userId: userId,
    accessToken: accessToken,
    customHeaders: customHeaders,
  );
}

final class _Session implements ActivationSessionPort {
  ActivationSessionSnapshot current = ActivationSessionSnapshot(
    sessionEpoch: 3,
    probeGeneration: 7,
    userId: 'cached-user',
    accessToken: 'current-token',
    customHeaders: const {'X-Second': 'two', 'X-First': 'one'},
  );

  @override
  ActivationSessionSnapshot snapshot() => ActivationSessionSnapshot(
    sessionEpoch: current.sessionEpoch,
    probeGeneration: current.probeGeneration,
    userId: current.userId,
    accessToken: current.accessToken,
    customHeaders: current.customHeaders,
  );
}

final class _GraphHandle implements PreparedApiGraph {
  const _GraphHandle(this.endpoint, this.identity, this.clientIdentity);

  final Uri endpoint;
  final Object identity;
  final int clientIdentity;
}

final class _Graph implements EndpointApiGraphPort {
  _Graph(this.events) {
    initialGraph = _GraphHandle(Uri.parse('https://old.test/api'), Object(), currentClientIdentity());
    installedGraphs.add(initialGraph);
  }

  final List<String> events;
  late final _GraphHandle initialGraph;
  final installedGraphs = <_GraphHandle>[];
  int Function() currentClientIdentity = () => 0;
  FutureOr<void> Function()? beforePrepare;
  var activationInstalled = false;
  var blocked = false;

  @override
  Uri? get currentEndpoint => installedGraphs.last.endpoint;

  @override
  void block() {
    events.add('graph.block.rollback');
    blocked = true;
    installedGraphs.add(_GraphHandle(Uri(), Object(), currentClientIdentity()));
  }

  @override
  Future<PreparedApiGraph> prepare(Uri apiEndpoint) async {
    await beforePrepare?.call();
    beforePrepare = null;
    if (activationInstalled || apiEndpoint == Uri()) events.add('graph.prepare.rollback');
    return _GraphHandle(apiEndpoint, Object(), currentClientIdentity());
  }

  @override
  Future<void> install(PreparedApiGraph graph) async {
    final graphHandle = graph as _GraphHandle;
    if (activationInstalled || graphHandle.endpoint == Uri()) events.add('graph.install.rollback');
    installedGraphs.add(graphHandle);
    blocked = graphHandle.endpoint == Uri();
    activationInstalled = true;
  }
}

final class _Native implements NativeRequestContextPort {
  _Native(this.events);

  final List<String> events;
  var replaced = false;
  var failAfterMutation = false;
  var clientIdentity = 1;
  var clearFailuresRemaining = 0;
  var blocked = false;
  var blockCalls = 0;
  var purgeCalls = 0;
  Completer<void>? replaceGate;
  final replaceStarted = Completer<void>();
  NativeRequestContext current = NativeRequestContext(
    canonicalOrigin: Uri.parse('https://old.test'),
    accessToken: 'old-token',
    schemePolicy: EndpointSchemePolicy.httpsOnly,
    customHeaders: const {'Old': 'header'},
  );

  @override
  NativeRequestContext snapshot() => NativeRequestContext(
    canonicalOrigin: current.canonicalOrigin,
    accessToken: current.accessToken,
    schemePolicy: current.schemePolicy,
    customHeaders: current.customHeaders,
  );

  @override
  void block() {
    events.add('native.block.rollback');
    blockCalls++;
    blocked = true;
  }

  @override
  Future<void> replace(NativeRequestContext context) async {
    if (replaced) events.add('native.replace.rollback');
    current = context;
    replaced = true;
    clientIdentity++;
    if (!replaceStarted.isCompleted) replaceStarted.complete();
    final gate = replaceGate;
    replaceGate = null;
    await gate?.future;
    if (failAfterMutation) {
      failAfterMutation = false;
      throw StateError('native replacement reply was lost');
    }
  }

  @override
  Future<void> purge() async {
    events.add('native.clear.rollback');
    purgeCalls++;
    clientIdentity++;
    if (clearFailuresRemaining > 0) {
      clearFailuresRemaining--;
      throw StateError('native clear failed');
    }
    current = NativeRequestContext(
      canonicalOrigin: null,
      accessToken: null,
      schemePolicy: null,
      customHeaders: const {},
    );
  }

  @override
  void publishCleared() {
    blocked = false;
  }
}

final class _Store implements ConfirmedEndpointStorePort {
  _Store(this.events);

  final List<String> events;
  var current = ConfirmedServerEndpoint(
    apiEndpoint: Uri.parse('https://old.test/api'),
    schemePolicy: EndpointSchemePolicy.httpsOnly,
  );
  var wroteActivation = false;

  @override
  ConfirmedServerEndpoint? read() => current;

  @override
  Future<void> write(ConfirmedServerEndpoint? endpoint) async {
    if (wroteActivation) events.add('store.write.rollback');
    if (endpoint != null) current = endpoint;
    wroteActivation = true;
  }
}

final class _Widget implements WidgetCredentialsPort {
  _Widget(this.events);

  final List<String> events;
  var current = const WidgetCredentials(apiEndpoint: null, accessToken: 'old-token', customHeaders: '{"Old":"header"}');
  var wroteActivation = false;
  var failNextWriteAfterActivation = false;
  var clearFailuresRemaining = 0;
  var hangOnClear = false;
  Completer<void>? clearGate;
  final clearStarted = Completer<void>();

  @override
  Future<WidgetCredentials> snapshot() async => WidgetCredentials(
    apiEndpoint: current.apiEndpoint,
    accessToken: current.accessToken,
    customHeaders: current.customHeaders,
  );

  @override
  Future<void> write(WidgetCredentials credentials) async {
    if (wroteActivation) {
      events.add('widget.write.rollback');
      if (failNextWriteAfterActivation) {
        failNextWriteAfterActivation = false;
        throw StateError('widget rollback failed');
      }
    }
    current = credentials;
    wroteActivation = true;
  }

  @override
  Future<void> clear() async {
    events.add('widget.clear.rollback');
    if (!clearStarted.isCompleted) clearStarted.complete();
    await clearGate?.future;
    if (hangOnClear) {
      await Completer<void>().future;
    }
    if (clearFailuresRemaining > 0) {
      clearFailuresRemaining--;
      throw StateError('widget clear failed');
    }
    current = const WidgetCredentials(apiEndpoint: null, accessToken: null, customHeaders: null);
  }
}
