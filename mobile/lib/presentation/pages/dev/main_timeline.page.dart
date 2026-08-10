import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_lane.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/asset_source_selector.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_source_filter.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sliver_tools/sliver_tools.dart';

@RoutePage()
class MainTimelinePage extends ConsumerWidget {
  const MainTimelinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final performance = ref.read(timelinePerformanceProvider);
    final sourceSelection = ref.watch(timelineSourceSelectionProvider);
    final authenticationPhase = ref.watch(remoteAuthenticationPhaseProvider);
    final reachabilityPhase = ref.watch(serverReachabilityStateProvider.select((state) => state.phase));
    final galleryPermission = ref.watch(galleryPermissionNotifier);

    return MainTimelineSafeViewport(
      child: Timeline(
        topSliverWidget: MainTimelineTopSlivers(
          source: sourceSelection.effectiveSource,
          selector: AssetSourceSelector(
            selectedSource: sourceSelection.effectiveSource,
            hasConfiguredServer: authenticationPhase != RemoteAuthenticationPhase.unconfigured,
            requiresReauthentication: authenticationPhase == RemoteAuthenticationPhase.reauthenticationRequired,
            reachabilityPhase: reachabilityPhase,
            galleryPermission: galleryPermission,
            onSourceSelected: (source) => unawaited(
              ref
                  .read(timelineSourceSelectionProvider.notifier)
                  .select(source)
                  .onError((error, stackTrace) => _showPreferenceError(context)),
            ),
            onConnectServer: () => unawaited(context.pushRoute(const LoginRoute())),
            onManageGalleryPermission: () => unawaited(openAppSettings()),
          ),
          memoryLaneBuilder: (context) => const DriftMemoryLane(),
        ),
        emptyWidget: MainTimelineEmptyState(
          messageKey: mainTimelineEmptyMessageKey(sourceSelection.effectiveSource, reachabilityPhase),
        ),
        errorWidgetBuilder: (error, stackTrace) =>
            MainTimelineErrorState(onRetry: () => ref.invalidate(timelineServiceProvider)),
        showStorageIndicator: true,
        onInteractive: performance.recordTimelineInteractive,
      ),
    );
  }

  void _showPreferenceError(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('timeline_source_save_error'.t(context: context))));
  }
}

class MainTimelineSafeViewport extends StatelessWidget {
  const MainTimelineSafeViewport({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(left: false, right: false, bottom: false, child: child);
}

class MainTimelineTopSlivers extends StatelessWidget {
  const MainTimelineTopSlivers({
    super.key,
    required this.source,
    required this.selector,
    required this.memoryLaneBuilder,
  });

  final TimelineSourceFilter source;
  final Widget selector;
  final WidgetBuilder memoryLaneBuilder;

  @override
  Widget build(BuildContext context) => MultiSliver(
    children: [
      SliverPinnedHeader(child: selector),
      if (source != TimelineSourceFilter.device) SliverToBoxAdapter(child: Builder(builder: memoryLaneBuilder)),
    ],
  );
}

String mainTimelineEmptyMessageKey(TimelineSourceFilter source, ReachabilityPhase reachability) {
  final isOffline = reachability == ReachabilityPhase.offline;
  return switch (source) {
    TimelineSourceFilter.device => 'timeline_empty_device',
    TimelineSourceFilter.combined => isOffline ? 'timeline_empty_combined_offline' : 'timeline_empty_combined',
    TimelineSourceFilter.server => isOffline ? 'timeline_empty_server_offline' : 'timeline_empty_server',
  };
}

class MainTimelineEmptyState extends StatelessWidget {
  const MainTimelineEmptyState({super.key, required this.messageKey});

  final String messageKey;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(messageKey.t(context: context), textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class MainTimelineErrorState extends StatelessWidget {
  const MainTimelineErrorState({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Text('timeline_load_error'.t(context: context), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onRetry,
            child: Text('timeline_try_again'.t(context: context)),
          ),
        ],
      ),
    ),
  );
}
