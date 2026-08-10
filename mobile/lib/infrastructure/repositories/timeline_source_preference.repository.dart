import 'package:immich_mobile/domain/interfaces/timeline_source_preference.interface.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';

final class StoreTimelineSourcePreference implements TimelineSourcePreferencePort {
  const StoreTimelineSourcePreference(this._store);

  final StoreService _store;

  @override
  int? readRaw() => _store.tryGet(StoreKey.timelineSourceFilter);

  @override
  Future<void> write(TimelineSourceFilter source) => _store.put(StoreKey.timelineSourceFilter, source.index);
}
