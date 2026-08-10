import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/main_timeline_query.interface.dart';
import 'package:immich_mobile/domain/models/setting.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/domain/services/main_timeline_factory.dart';
import 'package:immich_mobile/domain/services/setting.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  test('main source changes use only the focused database query port', () async {
    final mainQueries = _MockMainTimelineQueryPort();
    final settings = _MockSettingsService();
    when(() => settings.get(Setting.groupAssetsBy)).thenReturn(GroupAssetsBy.day.index);

    for (final source in TimelineSourceFilter.values) {
      when(() => mainQueries.main(const ['user'], GroupAssetsBy.day, source)).thenReturn(_emptyQuery);
    }

    final factory = MainTimelineFactory(queries: mainQueries, settingsService: settings);

    for (final source in TimelineSourceFilter.values) {
      final service = factory.create(const ['user'], source);
      expect(service.origin, TimelineOrigin.main);
      await service.dispose();
      verify(() => mainQueries.main(const ['user'], GroupAssetsBy.day, source)).called(1);
    }
  });
}

final MainTimelineQuery _emptyQuery = (assetSource: (_, _) async => const [], bucketSource: () => const Stream.empty());

final class _MockMainTimelineQueryPort extends Mock implements MainTimelineQueryPort {}

final class _MockSettingsService extends Mock implements SettingsService {}
