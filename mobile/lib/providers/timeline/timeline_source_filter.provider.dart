import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/timeline_source_preference.interface.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_selection.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline_source_preference.repository.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';

final timelineSourcePreferenceProvider = Provider<TimelineSourcePreferencePort>(
  (ref) => StoreTimelineSourcePreference(ref.watch(storeServiceProvider)),
);

final timelineSourceSelectionProvider = NotifierProvider<TimelineSourceSelectionNotifier, TimelineSourceSelection>(
  TimelineSourceSelectionNotifier.new,
);

final class TimelineSourceSelectionNotifier extends Notifier<TimelineSourceSelection> {
  @override
  TimelineSourceSelection build() {
    final phase = ref.watch(remoteAuthenticationPhaseProvider);
    final rawSource = ref.read(timelineSourcePreferenceProvider).readRaw();

    return TimelineSourceSelection.fromRaw(
      rawSource: rawSource,
      hasConfiguredServer: phase != RemoteAuthenticationPhase.unconfigured,
    );
  }

  Future<void> select(TimelineSourceFilter source) async {
    final previous = state;
    state = previous.copyWith(explicitSource: source);

    try {
      await ref.read(timelineSourcePreferenceProvider).write(source);
    } catch (_) {
      state = previous;
      rethrow;
    }
  }
}
