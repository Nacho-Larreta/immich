import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
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
    replaceNativeContext: (headers, origin, token) async {
      replacements.add(_NativeReplacement(headers, origin, token));
    },
  );

  test('cold start never restores a token from an uncommitted session', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: false);

    await init();

    expect(replacements.single, const _NativeReplacement({}, null, null));
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isFalse);
  });

  test('cold start rejects an endpoint whose scheme conflicts with its policy', () async {
    await _storeSession(endpoint: 'http://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);

    await init();

    expect(replacements.single, const _NativeReplacement({}, null, null));
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('http://photos.test')), isFalse);
  });

  test('legacy session without a readiness commit migrates to a restrictive tombstone', () async {
    await Store.put(StoreKey.serverEndpoint, 'https://photos.test/api');
    await Store.put(StoreKey.serverEndpointSchemePolicy, EndpointSchemePolicy.httpsOnly.name);
    await Store.put(StoreKey.accessToken, 'legacy-token');

    await init();

    expect(Store.tryGet(StoreKey.authenticatedSessionReady), isFalse);
    expect(replacements.single, const _NativeReplacement({}, null, null));
  });

  test('database migration does not reopen credentials after restrictive legacy migration', () async {
    await Store.put(StoreKey.version, 24);
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: false);
    await init();

    await migrateDatabaseIfNeeded();

    expect(Store.tryGet(StoreKey.version), targetVersion);
    expect(replacements, [const _NativeReplacement({}, null, null)]);
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isFalse);
  });

  test('cold start restores only a committed compatible non-local context', () async {
    await _storeSession(endpoint: 'https://photos.test/api', policy: EndpointSchemePolicy.httpsOnly, ready: true);

    await init();

    expect(replacements.single, const _NativeReplacement({'X-Server': 'header'}, 'https://photos.test', 'token'));
    expect(NetworkRepository.hasConfirmedRequestContext(Uri.parse('https://photos.test')), isTrue);
    expect(NetworkRepository.activeEndpointSchemePolicy, EndpointSchemePolicy.httpsOnly);
  });

  test('cold start never restores a WiFi-bound local HTTP lease', () async {
    await _storeSession(
      endpoint: 'http://photos.test/api',
      policy: EndpointSchemePolicy.registeredLocalHttp,
      ready: true,
    );

    await init();

    expect(replacements.single, const _NativeReplacement({}, null, null));
    expect(NetworkRepository.activeEndpointSchemePolicy, isNull);
  });
}

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
  const _NativeReplacement(this.headers, this.origin, this.token);

  final Map<String, String> headers;
  final String? origin;
  final String? token;

  @override
  bool operator ==(Object other) {
    return other is _NativeReplacement &&
        _mapsEqual(other.headers, headers) &&
        other.origin == origin &&
        other.token == token;
  }

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(headers.entries), origin, token);
}

bool _mapsEqual(Map<String, String> first, Map<String, String> second) {
  return first.length == second.length && first.entries.every((entry) => second[entry.key] == entry.value);
}
