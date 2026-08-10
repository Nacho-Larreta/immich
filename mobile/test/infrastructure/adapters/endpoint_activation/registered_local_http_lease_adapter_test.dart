import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/registered_local_http_lease_adapter.dart';

void main() {
  test('transport review blocks a local HTTP lease before asynchronous purge completes', () async {
    final purge = Completer<void>();
    var blocked = false;
    final lease = RegisteredLocalHttpLeaseAdapter(
      readActivePolicy: () => EndpointSchemePolicy.registeredLocalHttp,
      blockRequests: () => blocked = true,
      purgeRequestContext: () => purge.future,
    );

    final invalidated = lease.invalidateForTransportReview();

    expect(invalidated, isTrue);
    expect(blocked, isTrue);
    purge.complete();
    await pumpEventQueue();
  });

  test('transport review preserves explicitly approved HTTP context', () async {
    var blockCalls = 0;
    var purgeCalls = 0;
    final lease = RegisteredLocalHttpLeaseAdapter(
      readActivePolicy: () => EndpointSchemePolicy.explicitlyApprovedHttp,
      blockRequests: () => blockCalls++,
      purgeRequestContext: () async => purgeCalls++,
    );

    expect(lease.invalidateForTransportReview(), isFalse);
    lease.invalidateAfterValidationFailure();
    await pumpEventQueue();

    expect(blockCalls, 0);
    expect(purgeCalls, 0);
  });

  for (final activePolicy in [null, EndpointSchemePolicy.httpsOnly, EndpointSchemePolicy.registeredLocalHttp]) {
    test('transport review invalidates pending local HTTP activation over $activePolicy context', () async {
      var blockCalls = 0;
      var purgeCalls = 0;
      final adapter = RegisteredLocalHttpLeaseAdapter(
        readActivePolicy: () => activePolicy,
        blockRequests: () => blockCalls++,
        purgeRequestContext: () async => purgeCalls++,
      );
      final lease = adapter.beginActivation(EndpointSchemePolicy.registeredLocalHttp)!;

      expect(adapter.invalidateForTransportReview(), isTrue);
      expect(blockCalls, 1);
      expect(adapter.commitActivation(lease), isFalse);
      await pumpEventQueue();
      expect(purgeCalls, 1);
    });
  }

  test('a fresh local HTTP activation commits after a stale cycle', () async {
    final adapter = RegisteredLocalHttpLeaseAdapter(
      readActivePolicy: () => null,
      blockRequests: () {},
      purgeRequestContext: () async {},
    );
    final stale = adapter.beginActivation(EndpointSchemePolicy.registeredLocalHttp)!;
    adapter.invalidateForTransportReview();
    expect(adapter.commitActivation(stale), isFalse);

    final fresh = adapter.beginActivation(EndpointSchemePolicy.registeredLocalHttp)!;

    expect(adapter.commitActivation(fresh), isTrue);
  });

  test('validation failure blocks and purges an active local HTTP lease', () async {
    var blockCalls = 0;
    var purgeCalls = 0;
    final lease = RegisteredLocalHttpLeaseAdapter(
      readActivePolicy: () => EndpointSchemePolicy.registeredLocalHttp,
      blockRequests: () => blockCalls++,
      purgeRequestContext: () async => purgeCalls++,
    );

    lease.invalidateAfterValidationFailure();
    await pumpEventQueue();

    expect(blockCalls, 1);
    expect(purgeCalls, 1);
  });
}
