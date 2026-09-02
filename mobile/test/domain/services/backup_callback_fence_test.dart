import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/backup_callback_fence.dart';

void main() {
  test('fencing one owner rejects new permits, preserves other owners, and drains the live permit', () async {
    final fence = BackupCallbackFence();
    final livePermit = fence.tryBegin(runToken: 'run-a', bindingDigest: 'binding-a');
    expect(livePermit, isNotNull);
    var drained = false;
    final drain = fence
        .fenceAndDrain(runToken: 'run-a', bindingDigest: 'binding-a', timeout: const Duration(seconds: 1))
        .then((result) {
          drained = result;
          return result;
        });

    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    expect(fence.tryBegin(runToken: 'run-a', bindingDigest: 'binding-a'), isNull);

    final otherOwner = fence.tryBegin(runToken: 'run-b', bindingDigest: 'binding-b');
    expect(otherOwner, isNotNull);
    fence.end(otherOwner!);
    expect(drained, isFalse);

    fence.end(livePermit!);
    expect(await drain, isTrue);
    expect(fence.tryBegin(runToken: 'run-a', bindingDigest: 'binding-a'), isNull);
  });
}
