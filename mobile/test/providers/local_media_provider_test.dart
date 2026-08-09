import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/adapters/local_media/local_media_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/local_media/native_local_media_adapter.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/providers/local_media.provider.dart';

void main() {
  test('provider create, logout, login, and container dispose reuse one registration', () async {
    final host = _Host();
    final registration = _Registration();
    final container = ProviderContainer(
      overrides: [
        localMediaHostApiProvider.overrideWithValue(host),
        localMediaFlutterApiRegistrationProvider.overrideWithValue(registration.call),
      ],
    );

    final firstSession = container.read(localMediaProvider);
    expect(registration.calls, hasLength(1));

    await firstSession.cancelAll();
    final secondSession = container.read(localMediaProvider);
    expect(identical(firstSession, secondSession), isTrue);
    expect(registration.calls, hasLength(1));

    container.dispose();
    await pumpEventQueue();
    expect(registration.calls, [isA<NativeLocalMediaAdapter>(), null]);
    expect(host.cancelAllCount, 2);
    expect(host.disposeCount, 1);
  });

  test('provider disposal consumes native lifecycle failures at the Riverpod boundary', () async {
    final errors = <Object>[];
    final registration = _Registration();
    final host = _Host(cancelAllError: StateError('cancel channel failed'), disposeError: StateError('dispose failed'));

    final guarded = runZonedGuarded<Future<void>>(() async {
      final container = ProviderContainer(
        overrides: [
          localMediaHostApiProvider.overrideWithValue(host),
          localMediaFlutterApiRegistrationProvider.overrideWithValue(registration.call),
        ],
      );
      container.read(localMediaProvider);

      container.dispose();
      await pumpEventQueue();
    }, (error, _) => errors.add(error));

    await guarded;
    expect(errors, isEmpty);
    expect(registration.calls, [isA<NativeLocalMediaAdapter>(), null]);
    expect(host.cancelAllCount, 1);
    expect(host.disposeCount, 1);
  });
}

final class _Host implements LocalMediaHostApi {
  _Host({this.cancelAllError, this.disposeError});

  final Object? cancelAllError;
  final Object? disposeError;
  int cancelAllCount = 0;
  int disposeCount = 0;

  @override
  Future<LocalImageResult> requestImage(LocalImageRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> cancelRequest(int requestId) async {}

  @override
  Future<void> cancelAll() async {
    cancelAllCount++;
    final error = cancelAllError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    final error = disposeError;
    if (error != null) {
      throw error;
    }
  }
}

final class _Registration {
  final List<LocalImageFlutterApi?> calls = [];

  void call(LocalImageFlutterApi? api) => calls.add(api);
}
