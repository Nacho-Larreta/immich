import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';

typedef MainTimelineAssetSource = Future<List<BaseAsset>> Function(int index, int count);
typedef MainTimelineBucketSource = Stream<List<Bucket>> Function();
typedef MainTimelineQuery = ({MainTimelineAssetSource assetSource, MainTimelineBucketSource bucketSource});

abstract interface class MainTimelineQueryPort {
  MainTimelineQuery main(List<String> userIds, GroupAssetsBy groupBy, TimelineSourceFilter source);
}
