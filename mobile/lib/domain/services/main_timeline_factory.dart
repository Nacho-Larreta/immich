import 'package:immich_mobile/domain/interfaces/main_timeline_query.interface.dart';
import 'package:immich_mobile/domain/models/setting.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/domain/services/setting.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';

final class MainTimelineFactory {
  const MainTimelineFactory({required MainTimelineQueryPort queries, required SettingsService settingsService})
    : _queries = queries,
      _settingsService = settingsService;

  final MainTimelineQueryPort _queries;
  final SettingsService _settingsService;

  GroupAssetsBy get _groupBy {
    final group = GroupAssetsBy.values[_settingsService.get(Setting.groupAssetsBy)];
    return group == GroupAssetsBy.auto ? GroupAssetsBy.day : group;
  }

  TimelineService create(List<String> timelineUsers, TimelineSourceFilter source) =>
      TimelineService.main(_queries.main(timelineUsers, _groupBy, source));
}
