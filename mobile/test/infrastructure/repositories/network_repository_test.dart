import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/migration.dart';

void main() {
  late Drift db;
  late List<_NativeReplacement> replacements;

  setUpAll(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
  });

  setUp(() async {
    replacements = [];
    for (final key in [
      StoreKey.serverEndpoint,
      StoreKey.serverEndpointSchemePolicy,
      StoreKey.authenticatedSessionReady,
      StoreKey.accessToken,
      StoreKey.customHeaders,
      StoreKey.version,
    ]) {
      await Store.delete(key);
    }
  });

  tearDownAll(() => db.close());

  Future<void> init() => NetworkRepository.initForTest(
    replaceNativeContext: (headers, endpoint, origin, policy, token, sessionEpoch) async {
      replacements.add(_NativeReplacement(headers, endpoint, origin, policy, token));
    },
  );

  test('cold start never restores a token from an uncommitted session', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: false);

    await init();

    expect(replacements.single, const _NativeReplacement({}, null, null, null, null));
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isFalse);
  });

  test('cold start rejects an endpoint whose scheme conflicts with its policy', () async {
    await _storeSession(endpoint: 'http://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);

    await init();

    expect(replacements.single, const _NativeReplacement({}, null, null, null, null));
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('http://photos.test')), isFalse);
  });

  test('legacy session without a readiness commit migrates to a restrictive tombstone', () async {
    await Store.put(StoreKey.serverEndpoint, 'https://photos.test/api');
    await Store.put(StoreKey.serverEndpointSchemePolicy, EndpointSchemePolicy.httpsOnly.name);
    await Store.put(StoreKey.accessToken, 'legacy-token');

    await init();

    expect(Store.tryGet(StoreKey.authenticatedSessionReady), isFalse);
    expect(replacements.single, const _NativeReplacement({}, null, null, null, null));
  });

  test('database migration does not reopen credentials after restrictive legacy migration', () async {
    await Store.put(StoreKey.version, 24);
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: false);
    await init();

    await migrateDatabaseIfNeeded();

    expect(Store.tryGet(StoreKey.version), targetVersion);
    expect(replacements, [const _NativeReplacement({}, null, null, null, null)]);
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isFalse);
  });

  test('cold start restores only a committed compatible non-local context', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);

    await init();

    expect(
      replacements.single,
      const _NativeReplacement(
        {'X-Server': 'header'},
        'https://photos.test/api',
        'https://photos.test',
        NetworkEndpointSchemePolicy.httpsOnly,
        'token',
      ),
    );
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isTrue);
    expect(NetworkRepository.activeEndpointSchemePolicy, EndpointSchemePolicy.httpsOnly);
    expect(NetworkRepository.serverAccessEvidence.apiEndpoint, Uri.parse('https://photos.test/api'));
  });

  test('explicit HTTP approval crosses the root to native descriptor without scheme inference', () async {
    await _storeSession(
      endpoint: 'http://photos.test/api',
      policy: EndpointSchemePolicy.explicitlyApprovedHttp,
      ready: true,
    );

    await init();

    expect(replacements.single.endpoint, 'http://photos.test/api');
    expect(replacements.single.origin, 'http://photos.test');
    expect(replacements.single.policy, NetworkEndpointSchemePolicy.explicitlyApprovedHttp);
  });

  test('attached worker rejects exact native and Store policy mismatch', () async {
    await _storeSession(
      endpoint: 'http://photos.test/api',
      policy: EndpointSchemePolicy.explicitlyApprovedHttp,
      ready: true,
    );

    NetworkRepository.attachNativeSnapshotForTest(
      NetworkRequestContextSnapshot(
        clientPointer: 1,
        apiEndpoint: 'http://photos.test/api',
        canonicalOrigin: 'http://photos.test',
        schemePolicy: NetworkEndpointSchemePolicy.registeredLocalHttp,
        sessionEpoch: 4,
        generation: 8,
        transportIncarnation: 'attached-process',
        confirmed: true,
      ),
    );

    expect(NetworkRepository.serverAccessEvidence.confirmed, isFalse);
    expect(NetworkRepository.serverAccessEvidence.fenced, isTrue);
  });

  final invalidAttachedStoreCases = <({String name, Future<void> Function() arrange})>[
    (name: 'missing endpoint', arrange: () => Store.delete(StoreKey.serverEndpoint)),
    (name: 'invalid endpoint', arrange: () => Store.put(StoreKey.serverEndpoint, 'not-an-http-endpoint')),
    (name: 'endpoint mismatch', arrange: () => Store.put(StoreKey.serverEndpoint, 'http://other.test/api')),
    (name: 'missing policy', arrange: () => Store.delete(StoreKey.serverEndpointSchemePolicy)),
    (name: 'invalid policy', arrange: () => Store.put(StoreKey.serverEndpointSchemePolicy, 'approved-http')),
  ];

  for (final testCase in invalidAttachedStoreCases) {
    test('attached worker rejects ${testCase.name} corroboration', () async {
      await _storeSession(
        endpoint: 'http://photos.test/api',
        policy: EndpointSchemePolicy.explicitlyApprovedHttp,
        ready: true,
      );
      await testCase.arrange();

      NetworkRepository.attachNativeSnapshotForTest(_explicitHttpNativeSnapshot());

      expect(NetworkRepository.serverAccessEvidence.confirmed, isFalse);
      expect(NetworkRepository.serverAccessEvidence.fenced, isTrue);
    });
  }

  test('attached worker accepts exact persisted explicit HTTP corroboration', () async {
    await _storeSession(
      endpoint: 'http://photos.test/api',
      policy: EndpointSchemePolicy.explicitlyApprovedHttp,
      ready: true,
    );

    NetworkRepository.attachNativeSnapshotForTest(_explicitHttpNativeSnapshot());

    expect(NetworkRepository.serverAccessEvidence.confirmed, isTrue);
    expect(NetworkRepository.serverAccessEvidence.fenced, isFalse);
    expect(NetworkRepository.activeEndpointSchemePolicy, EndpointSchemePolicy.explicitlyApprovedHttp);
  });

  test('runtime proof is immutable when Store changes and is replaced only by a runtime transition', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);
    await init();
    final restored = NetworkRepository.serverAccessEvidence;

    await Store.put(StoreKey.serverEndpoint, 'https://photos.test/changed-api');
    await Store.put(StoreKey.serverEndpointSchemePolicy, EndpointSchemePolicy.explicitlyApprovedHttp.name);

    expect(NetworkRepository.serverAccessEvidence, same(restored));
    expect(NetworkRepository.serverAccessEvidence.apiEndpoint, Uri.parse('https://photos.test/api'));

    await Store.put(StoreKey.serverEndpoint, 'https://photos.test/runtime-api');
    await Store.put(StoreKey.serverEndpointSchemePolicy, EndpointSchemePolicy.httpsOnly.name);
    await init();

    expect(NetworkRepository.serverAccessEvidence, isNot(same(restored)));
    expect(NetworkRepository.serverAccessEvidence.apiEndpoint, Uri.parse('https://photos.test/runtime-api'));
  });

  test('binding failure after native confirmation purges natively and keeps Dart fenced', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);
    final events = <String>[];

    await expectLater(
      NetworkRepository.initForTest(
        replaceNativeContext: (headers, endpoint, origin, policy, token, sessionEpoch) async =>
            events.add('replace:$origin'),
        bindNativeClient: () async {
          events.add('bind');
          throw StateError('snapshot failed');
        },
        failClosedNativeContext: () async => events.add('purge'),
      ),
      throwsStateError,
    );

    expect(events, ['replace:https://photos.test', 'bind', 'purge']);
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isFalse);
  });

  test('purge drain timeout still purges native context unconfirmed before propagating', () async {
    final events = <String>[];
    const timeout = NetworkTransportDrainTimeout(Duration(seconds: 5));

    await expectLater(
      NetworkRepository.purgeRequestContextForTest(
        drainTransport: () async {
          events.add('drain');
          throw timeout;
        },
        replaceNativeContext: (headers, endpoint, origin, policy, token, sessionEpoch) async => events.add('replace'),
        bindNativeClient: () async => events.add('bind'),
        failClosedNativeContext: () async => events.add('failClosed'),
      ),
      throwsA(same(timeout)),
    );

    expect(events, ['drain', 'failClosed']);
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isFalse);
  });

  for (final transport in ['HTTP', 'WebSocket']) {
    test('purge fail-closes once when $transport cancellation throws', () async {
      final events = <String>[];
      final cancellationError = StateError('$transport cancellation failed');

      await expectLater(
        NetworkRepository.purgeRequestContextForTest(
          drainTransport: () async {
            events.add('drain');
            throw cancellationError;
          },
          replaceNativeContext: (headers, endpoint, origin, policy, token, sessionEpoch) async => events.add('replace'),
          bindNativeClient: () async => events.add('bind'),
          failClosedNativeContext: () async => events.add('failClosed'),
        ),
        throwsA(same(cancellationError)),
      );

      expect(events, ['drain', 'failClosed']);
    });
  }

  test('genuine replacement drain timeout never calls native replacement or purge', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);
    final events = <String>[];
    const timeout = NetworkTransportDrainTimeout(Duration(seconds: 5));

    await expectLater(
      NetworkRepository.initForTest(
        drainTransport: () async {
          events.add('drain');
          throw timeout;
        },
        replaceNativeContext: (headers, endpoint, origin, policy, token, sessionEpoch) async => events.add('replace'),
        failClosedNativeContext: () async => events.add('failClosed'),
      ),
      throwsA(same(timeout)),
    );

    expect(events, ['drain']);
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isFalse);
  });

  test('cold start never restores a WiFi-bound local HTTP lease', () async {
    await _storeSession(
      endpoint: 'http://photos.test/api',
      policy: EndpointSchemePolicy.registeredLocalHttp,
      ready: true,
    );

    await init();

    expect(replacements.single, const _NativeReplacement({}, null, null, null, null));
    expect(NetworkRepository.activeEndpointSchemePolicy, isNull);
  });

  test('native bindings preserve the client retained by an existing API graph', () async {
    final first = MockClient((_) async => Response('', 200));
    final second = MockClient((_) async => Response('', 200));
    NetworkRepository.bindClientForTest(first);
    final retainedClient = NetworkRepository.client;
    final apiService = ApiService(initialEndpoint: 'https://photos.test/api');

    NetworkRepository.bindClientForTest(second);

    expect(NetworkRepository.client, same(retainedClient));
    expect(apiService.apiClient.client, same(retainedClient));
  });

  test('attached workers reject WebSocket creation before native transport access', () async {
    NetworkRepository.setContextRoleForTest(NetworkContextRole.attachedWorker);
    try {
      await expectLater(
        NetworkRepository.createWebSocket(Uri.parse('wss://photos.test/api/socket.io')),
        throwsA(isA<StateError>()),
      );
    } finally {
      NetworkRepository.setContextRoleForTest(NetworkContextRole.rootWriter);
    }
  });

  test('login transport rotation makes the retained API graph use the authenticated native client', () async {
    final anonymousPaths = <String>[];
    final authenticatedPaths = <String>[];
    NetworkRepository.bindClientForTest(
      MockClient((request) async {
        anonymousPaths.add(request.url.path);
        return Response('', 200);
      }),
    );
    final apiService = ApiService(initialEndpoint: 'https://photos.test/api');
    final retainedClient = apiService.apiClient.client;

    await retainedClient.post(Uri.parse('https://photos.test/api/auth/login'));
    NetworkRepository.bindClientForTest(
      MockClient((request) async {
        authenticatedPaths.add(request.url.path);
        return Response('', 200);
      }),
    );
    final currentUser = await retainedClient.get(Uri.parse('https://photos.test/api/users/me'));

    expect(currentUser.statusCode, 200);
    expect(anonymousPaths, ['/api/auth/login']);
    expect(authenticatedPaths, ['/api/users/me']);
  });

  test('foreground identity capture fails closed when Dart authority blocks during native proof', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);
    NetworkRepository.attachNativeSnapshotForTest(_httpsNativeSnapshot());
    NetworkRepository.setContextRoleForTest(NetworkContextRole.rootWriter);
    final readStarted = Completer<void>();
    final releaseRead = Completer<void>();

    final capture = NetworkRepository.captureForegroundTransportIdentityForTest(
      readIdentity: () async {
        readStarted.complete();
        await releaseRead.future;
        return NetworkTransportIdentitySnapshot(incarnation: 'root-process', generation: 8, confirmed: true);
      },
    );
    await readStarted.future;
    NetworkRepository.blockRequests();
    releaseRead.complete();

    expect(await capture, isNull);
  });

  test('foreground retirement completes exact rebind before a queued purge can mutate native context', () async {
    final events = <String>[];
    final retirementStarted = Completer<void>();
    final releaseRetirement = Completer<void>();
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'legacy-claim',
      bindingDigest: 'binding-digest',
      nativeGeneration: 7,
    );

    final retirement = NetworkRepository.retireForegroundTransportClaimsForTest(
      {claim},
      const Duration(seconds: 1),
      retireNativeTransports: (_) async {
        events.add('retirement.start');
        retirementStarted.complete();
        await releaseRetirement.future;
        events.add('retirement.end');
        return NetworkTransportRetirementStatus.retired;
      },
      readIdentity: () async {
        events.add('retirement.identity');
        return NetworkTransportIdentitySnapshot(incarnation: 'root-process', generation: 9, confirmed: true);
      },
      readExactSnapshot: (incarnation, generation) async {
        events.add('retirement.snapshot:$incarnation:$generation');
        return _httpsNativeSnapshot(generation: generation);
      },
      bindNativeSnapshot: (snapshot, {required keepFence}) {
        events.add('retirement.bind:$keepFence:${snapshot.generation}');
      },
    );
    await retirementStarted.future;
    final purge = NetworkRepository.purgeRequestContextForTest(
      drainTransport: () async => events.add('purge.drain'),
      replaceNativeContext: (headers, endpoint, origin, policy, token, sessionEpoch) async {
        events.add('purge.replace');
      },
      bindNativeClient: () async => events.add('purge.bind'),
      failClosedNativeContext: () async => events.add('purge.failClosed'),
    );
    await pumpEventQueue();

    expect(events, ['retirement.start']);
    releaseRetirement.complete();
    expect(await retirement, ForegroundTransportRetirement.retired);
    await purge;
    expect(events, [
      'retirement.start',
      'retirement.end',
      'retirement.identity',
      'retirement.snapshot:root-process:9',
      'retirement.bind:true:9',
      'purge.drain',
      'purge.replace',
      'purge.bind',
    ]);
  });

  test('foreground retirement rejects a full snapshot that misses the proven native identity', () async {
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'legacy-claim',
      bindingDigest: 'binding-digest',
      nativeGeneration: 7,
    );
    var bindCalls = 0;

    final result = await NetworkRepository.retireForegroundTransportClaimsForTest(
      {claim},
      const Duration(seconds: 1),
      retireNativeTransports: (_) async => NetworkTransportRetirementStatus.retired,
      readIdentity: () async =>
          NetworkTransportIdentitySnapshot(incarnation: 'root-process', generation: 9, confirmed: true),
      readExactSnapshot: (_, _) async => _httpsNativeSnapshot(generation: 10),
      bindNativeSnapshot: (_, {required keepFence}) => bindCalls++,
    );

    expect(result, ForegroundTransportRetirement.temporarilyUnproven);
    expect(bindCalls, 0);
  });
}

NetworkRequestContextSnapshot _explicitHttpNativeSnapshot() => NetworkRequestContextSnapshot(
  clientPointer: 1,
  apiEndpoint: 'http://photos.test/api',
  canonicalOrigin: 'http://photos.test',
  schemePolicy: NetworkEndpointSchemePolicy.explicitlyApprovedHttp,
  sessionEpoch: 4,
  generation: 8,
  transportIncarnation: 'root-process',
  confirmed: true,
);

NetworkRequestContextSnapshot _httpsNativeSnapshot({int generation = 8}) => NetworkRequestContextSnapshot(
  clientPointer: 1,
  apiEndpoint: 'https://photos.test/api',
  canonicalOrigin: 'https://photos.test',
  schemePolicy: NetworkEndpointSchemePolicy.httpsOnly,
  sessionEpoch: 4,
  generation: generation,
  transportIncarnation: 'root-process',
  confirmed: true,
);

Future<void> _storeSession({
  required String endpoint,
  required EndpointSchemePolicy policy,
  required bool ready,
}) async {
  await Store.put(StoreKey.serverEndpoint, endpoint);
  await Store.put(StoreKey.serverEndpointSchemePolicy, policy.name);
  await Store.put(StoreKey.authenticatedSessionReady, ready);
  await Store.put(StoreKey.accessToken, 'token');
  await Store.put(StoreKey.customHeaders, '{"X-Server":"header"}');
}

final class _NativeReplacement {
  const _NativeReplacement(this.headers, this.endpoint, this.origin, this.policy, this.token);

  final Map<String, String> headers;
  final String? endpoint;
  final String? origin;
  final NetworkEndpointSchemePolicy? policy;
  final String? token;

  @override
  bool operator ==(Object other) {
    return other is _NativeReplacement &&
        _mapsEqual(other.headers, headers) &&
        other.endpoint == endpoint &&
        other.origin == origin &&
        other.policy == policy &&
        other.token == token;
  }

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(headers.entries), endpoint, origin, policy, token);
}

bool _mapsEqual(Map<String, String> first, Map<String, String> second) {
  return first.length == second.length && first.entries.every((entry) => second[entry.key] == entry.value);
}
