import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';

final class RemoteAlbumViewerSession {
  const RemoteAlbumViewerSession({required this.scope, required this.timeline});

  final RemoteAlbumScope scope;
  final TimelineService timeline;

  bool matches(RemoteAlbumScope? currentScope) => currentScope == scope;
}
