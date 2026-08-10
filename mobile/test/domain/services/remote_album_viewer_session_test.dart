import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/services/remote_album_viewer_session.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockTimelineService extends Mock implements TimelineService {}

void main() {
  const scopeA = RemoteAlbumScope(
    viewer: RemoteViewerScope(viewerId: 'A', sessionEpoch: 1),
    albumId: 'album',
  );

  test('preserves an album activity timeline only while its original viewer scope is current', () {
    final timeline = _MockTimelineService();
    when(() => timeline.origin).thenReturn(TimelineOrigin.albumActivities);
    final session = RemoteAlbumViewerSession(scope: scopeA, timeline: timeline);

    expect(session.timeline, same(timeline));
    expect(session.timeline.origin, TimelineOrigin.albumActivities);
    expect(session.matches(scopeA), isTrue);
    expect(
      session.matches(
        const RemoteAlbumScope(
          viewer: RemoteViewerScope(viewerId: 'B', sessionEpoch: 2),
          albumId: 'album',
        ),
      ),
      isFalse,
    );
  });
}
