import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/isolate.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  test('product isolate computation propagates success after cleanup', () async {
    var cleanedUp = false;

    final result = await executeBackgroundComputation(
      computation: () async => 7,
      cleanup: () async => cleanedUp = true,
    );

    expect(result, 7);
    expect(cleanedUp, isTrue);
  });

  test('product isolate computation propagates errors after cleanup', () async {
    var cleanedUp = false;

    final result = executeBackgroundComputation<void>(
      computation: () async => throw StateError('sync failed'),
      cleanup: () async => cleanedUp = true,
    );

    await expectLater(result, throwsStateError);
    expect(cleanedUp, isTrue);
  });

  test('product isolate computation propagates cancellation after cleanup', () async {
    var cleanedUp = false;

    final result = executeBackgroundComputation<void>(
      computation: () async => throw CanceledError(),
      cleanup: () async => cleanedUp = true,
    );

    await expectLater(result, throwsA(isA<CanceledError>()));
    expect(cleanedUp, isTrue);
  });
}
