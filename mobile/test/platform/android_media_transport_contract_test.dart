import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('android/app/src/main/kotlin/app/alextran/immich/core/HttpClientManager.kt').readAsStringSync();
  final remoteImages = File(
    'android/app/src/main/kotlin/app/alextran/immich/images/RemoteImagesImpl.kt',
  ).readAsStringSync();
  final requestContext = File(
    'android/app/src/main/kotlin/app/alextran/immich/core/RemoteImageRequestContext.kt',
  ).readAsStringSync();
  final cacheExecutor = File(
    'android/app/src/main/kotlin/app/alextran/immich/images/RemoteImageCacheExecutor.kt',
  ).readAsStringSync();
  final diskCache = File(
    'android/app/src/main/kotlin/app/alextran/immich/images/RemoteImageDiskCache.kt',
  ).readAsStringSync();

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

  test('remote media rejects generation N after context advances to N plus 1', () {
    final authorization = _between(source, 'fun captureRemoteImageAuthorization', 'suspend fun rebuildCronetEngine');
    final admission = _between(remoteImages, 'override fun requestImage', 'override fun cancelRequest');

    expect(requestContext, contains('!confirmed || replacing || generation != expectedGeneration'));
    expect(authorization, contains('fun admitRemoteImageRequest'));
    expect(requestContext, contains('active != declared'));
    expect(authorization, contains('fun isRemoteImageContextCurrent'));
    expect(authorization, contains('fun claimRemoteImageCompletion'));
    expect(authorization, contains('fun deliverRemoteImageCache'));

    final cacheOnly = admission.indexOf('request.policy == RemoteImagePolicy.CACHE_ONLY');
    final generation = admission.indexOf('val expectedGeneration = request.expectedContextGeneration');
    final credentials = admission.indexOf('HttpClientManager.captureRemoteImageAuthorization');
    final linearizedAdmission = admission.indexOf('HttpClientManager.admitRemoteImageRequest');
    final registration = admission.indexOf('requestMap[request.requestId]');
    final completionClaim = admission.lastIndexOf('HttpClientManager.claimRemoteImageCompletion');
    final completionAdmission = admission.lastIndexOf('HttpClientManager.deliverRemoteImageCache');

    expect(cacheOnly, greaterThanOrEqualTo(0));
    expect(generation, greaterThan(cacheOnly));
    expect(credentials, greaterThan(generation));
    expect(linearizedAdmission, greaterThan(credentials));
    expect(registration, greaterThan(linearizedAdmission));
    expect(completionClaim, greaterThan(registration));
    expect(completionAdmission, greaterThan(completionClaim));
  });

  test('cache-only uses a bounded off-main cache boundary without credentials or network', () {
    final cacheOnly = _between(remoteImages, 'private fun requestCachedImage', 'private fun completeRequest');

    expect(cacheOnly, contains('claimRemoteImageCacheRead'));
    expect(cacheOnly, contains('ImageFetcherManager.readCache'));
    expect(cacheOnly, contains('deliverRemoteImageCache'));
    expect(cacheOnly, isNot(contains('captureRemoteImageAuthorization')));
    expect(cacheOnly, isNot(contains('ImageFetcherManager.fetch')));
    expect(cacheExecutor, contains('ArrayBlockingQueue'));
    expect(cacheExecutor, contains('RemoteImageCacheExecutor'));
    expect(diskCache, contains('maxTotalBytes'));
    expect(diskCache, contains('maxEntries'));
    expect(diskCache, contains('RemoteImageCacheScope'));

    final preparedWrite = _between(remoteImages, 'fun prepareCacheWrite', 'fun clearCache');
    expect(preparedWrite.indexOf('cacheExecutor.reserve'), lessThan(preparedWrite.indexOf('ByteArray')));
    expect(remoteImages, contains('cacheExecutor.submitBarrier { diskCache.retainOnly(scope) }'));
  });

  test('OkHttp disables automatic redirects and exact-context policy owns each hop', () {
    expect(remoteImages, contains('.followRedirects(false)'));
    expect(remoteImages, contains('.followSslRedirects(false)'));
    expect(remoteImages, contains('MAX_REDIRECTS'));
    expect(remoteImages, contains('isRemoteImageContextCurrent'));
    expect(remoteImages, contains('response.header("Location")'));
  });
}

String _between(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'Missing $startMarker');
  expect(end, greaterThan(start), reason: 'Missing $endMarker after $startMarker');
  return source.substring(start, end);
}
