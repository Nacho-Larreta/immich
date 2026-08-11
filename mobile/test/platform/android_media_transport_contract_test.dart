import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('android/app/src/main/kotlin/app/alextran/immich/core/HttpClientManager.kt').readAsStringSync();

  test('Media3 uses the request-context OkHttp dispatcher', () {
    final mediaFactory = _between(source, 'fun createDataSourceFactory', 'fun buildCronetEngine');

    expect(mediaFactory, contains('buildContextBoundMediaClient()'));
    expect(mediaFactory, contains('OkHttpDataSource.Factory'));
    expect(mediaFactory, isNot(contains('CronetDataSource.Factory')));
    expect(mediaFactory, contains('getAuthHeaders(dataSpec.uri.toString())'));
    expect(mediaFactory, contains('newHeaders["Cache-Control"] = "no-store"'));
    expect(mediaFactory, contains('ContextBoundDataSourceFactory(delegate)'));

    final mediaClient = _between(source, 'private fun buildContextBoundMediaClient', 'fun buildCronetEngine');
    expect(mediaClient, contains('client.newBuilder()'));
    expect(mediaClient, contains('mediaClient.dispatcher === client.dispatcher'));
  });

  test('request-context transition cancels calls before acknowledging drain', () {
    final transition = _between(
      source,
      'private fun transitionRequestContext',
      'private fun cancelOkHttpWorkAndAwaitIdle',
    );
    final drain = _between(source, 'private fun cancelOkHttpWorkAndAwaitIdle', 'private fun listenersForChange');

    final fence = transition.indexOf('requestContextConfirmed = false');
    final cancellation = transition.indexOf('cancelOkHttpWorkAndAwaitIdle()');
    final cancel = drain.indexOf('dispatcher.cancelAll()');
    final immediateIdleCheck = drain.indexOf('dispatcher.queuedCallsCount()');
    final completion = drain.indexOf('drained.complete(Unit)');

    expect(fence, greaterThanOrEqualTo(0));
    expect(cancellation, greaterThan(fence));
    expect(transition, contains('NetworkContextBoundWorkRegistry.fenceAndCancelAll(transitionEpoch)'));
    expect(transition, contains('.get(REQUEST_CONTEXT_DRAIN_TIMEOUT_SECONDS, TimeUnit.SECONDS)'));
    expect(cancel, greaterThanOrEqualTo(0));
    expect(immediateIdleCheck, greaterThan(cancel));
    expect(completion, greaterThanOrEqualTo(0));
    expect(drain, contains('dispatcher.idleCallback = onIdle'));
  });
}

String _between(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing $startMarker');
  expect(end, greaterThan(start), reason: 'Missing $endMarker after $startMarker');
  return source.substring(start, end);
}
