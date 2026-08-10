import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';

final class TimelineSourceSelection {
  const TimelineSourceSelection({required this.explicitSource, required this.hasConfiguredServer});

  factory TimelineSourceSelection.fromRaw({required int? rawSource, required bool hasConfiguredServer}) {
    final explicitSource = rawSource != null && rawSource >= 0 && rawSource < TimelineSourceFilter.values.length
        ? TimelineSourceFilter.values[rawSource]
        : null;

    return TimelineSourceSelection(explicitSource: explicitSource, hasConfiguredServer: hasConfiguredServer);
  }

  final TimelineSourceFilter? explicitSource;
  final bool hasConfiguredServer;

  TimelineSourceFilter get effectiveSource {
    if (!hasConfiguredServer) {
      return TimelineSourceFilter.device;
    }

    return explicitSource ?? TimelineSourceFilter.combined;
  }

  TimelineSourceSelection copyWith({TimelineSourceFilter? explicitSource, bool? hasConfiguredServer}) =>
      TimelineSourceSelection(
        explicitSource: explicitSource ?? this.explicitSource,
        hasConfiguredServer: hasConfiguredServer ?? this.hasConfiguredServer,
      );
}
