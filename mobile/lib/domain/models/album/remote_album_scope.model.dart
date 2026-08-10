final class RemoteViewerScope {
  const RemoteViewerScope({required this.viewerId, required this.sessionEpoch});

  final String viewerId;
  final int sessionEpoch;

  @override
  bool operator ==(Object other) {
    return other is RemoteViewerScope && other.viewerId == viewerId && other.sessionEpoch == sessionEpoch;
  }

  @override
  int get hashCode => Object.hash(viewerId, sessionEpoch);
}

final class RemoteAlbumScope {
  const RemoteAlbumScope({required this.viewer, required this.albumId});

  final RemoteViewerScope viewer;
  final String albumId;

  String get viewerId => viewer.viewerId;
  int get sessionEpoch => viewer.sessionEpoch;

  @override
  bool operator ==(Object other) {
    return other is RemoteAlbumScope && other.viewer == viewer && other.albumId == albumId;
  }

  @override
  int get hashCode => Object.hash(viewer, albumId);
}

final class RemoteAlbumActivityScope {
  const RemoteAlbumActivityScope({required this.album, this.assetId});

  final RemoteAlbumScope album;
  final String? assetId;

  String get albumId => album.albumId;

  @override
  bool operator ==(Object other) {
    return other is RemoteAlbumActivityScope && other.album == album && other.assetId == assetId;
  }

  @override
  int get hashCode => Object.hash(album, assetId);
}
