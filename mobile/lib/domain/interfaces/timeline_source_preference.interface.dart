import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';

abstract interface class TimelineSourcePreferencePort {
  int? readRaw();

  Future<void> write(TimelineSourceFilter source);
}
