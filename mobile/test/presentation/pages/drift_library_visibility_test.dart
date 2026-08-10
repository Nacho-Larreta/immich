import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/presentation/pages/drift_library.page.dart';

void main() {
  test('reauthentication keeps cached people but hides destinations guarded by authentication', () {
    final visibility = LibrarySurfaceVisibility.from(
      const ServerAccessPolicy.reauthenticationRequired(),
      viewerId: 'cached-viewer',
    );

    expect(visibility.showCachedPeople, isTrue);
    expect(visibility.showRemoteDestinations, isFalse);
  });

  test('online viewer sees remote destinations', () {
    final visibility = LibrarySurfaceVisibility.from(const ServerAccessPolicy.online(), viewerId: 'viewer');

    expect(visibility.showCachedPeople, isTrue);
    expect(visibility.showRemoteDestinations, isTrue);
  });
}
