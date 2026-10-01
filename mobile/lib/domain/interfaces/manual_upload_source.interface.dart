import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

final class ManualUploadSource {
  const ManualUploadSource({
    required this.asset,
    required this.isLivePhoto,
    required this.primaryBorrowedPath,
    required this.primaryOriginalFileName,
    this.motionBorrowedPath,
    this.motionOriginalFileName,
  });

  final LocalAsset asset;
  final bool isLivePhoto;
  final String primaryBorrowedPath;
  final String primaryOriginalFileName;
  final String? motionBorrowedPath;
  final String? motionOriginalFileName;
}

abstract interface class ManualUploadSourcePort {
  Future<ManualUploadSource?> load(String localAssetId);
}
