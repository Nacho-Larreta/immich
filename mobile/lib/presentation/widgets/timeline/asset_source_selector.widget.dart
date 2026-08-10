import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:permission_handler/permission_handler.dart';

class AssetSourceSelector extends StatelessWidget {
  const AssetSourceSelector({
    super.key,
    required this.selectedSource,
    required this.hasConfiguredServer,
    required this.requiresReauthentication,
    required this.reachabilityPhase,
    required this.galleryPermission,
    required this.onSourceSelected,
    required this.onConnectServer,
    required this.onManageGalleryPermission,
  });

  final TimelineSourceFilter selectedSource;
  final bool hasConfiguredServer;
  final bool requiresReauthentication;
  final ReachabilityPhase reachabilityPhase;
  final PermissionStatus galleryPermission;
  final ValueChanged<TimelineSourceFilter> onSourceSelected;
  final VoidCallback onConnectServer;
  final VoidCallback onManageGalleryPermission;

  @override
  Widget build(BuildContext context) {
    final showServerStatus =
        hasConfiguredServer && !requiresReauthentication && selectedSource != TimelineSourceFilter.device;
    final showGalleryStatus = selectedSource != TimelineSourceFilter.server;

    return Material(
      color: context.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              container: true,
              label: 'timeline_source_label'.t(context: context),
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: SegmentedButton<TimelineSourceFilter>(
                      key: const ValueKey('timeline-source-segmented-control'),
                      showSelectedIcon: false,
                      style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 48))),
                      segments: [
                        ButtonSegment(
                          value: TimelineSourceFilter.device,
                          label: Text('timeline_source_device'.t(context: context)),
                        ),
                        ButtonSegment(
                          value: TimelineSourceFilter.combined,
                          label: Text('timeline_source_combined'.t(context: context)),
                        ),
                        ButtonSegment(
                          value: TimelineSourceFilter.server,
                          label: Text('timeline_source_server'.t(context: context)),
                        ),
                      ],
                      selected: {selectedSource},
                      onSelectionChanged: (selection) {
                        final source = selection.first;
                        if (!hasConfiguredServer && source != TimelineSourceFilter.device) {
                          onConnectServer();
                          return;
                        }
                        onSourceSelected(source);
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (requiresReauthentication) ...[
              const SizedBox(height: 8),
              _StatusRow(
                icon: Icons.lock_reset_outlined,
                message: 'timeline_source_reauthentication_required'.t(context: context),
                actionLabel: 'timeline_source_reconnect_server'.t(context: context),
                onAction: onConnectServer,
              ),
            ] else if (!hasConfiguredServer) ...[
              const SizedBox(height: 8),
              _StatusRow(
                icon: Icons.cloud_off_outlined,
                message: 'timeline_source_no_server'.t(context: context),
                actionLabel: 'timeline_source_connect_server'.t(context: context),
                onAction: onConnectServer,
              ),
            ],
            if (showServerStatus && reachabilityPhase == ReachabilityPhase.probing) ...[
              const SizedBox(height: 8),
              Semantics(
                label: 'timeline_source_probing'.t(context: context),
                child: const LinearProgressIndicator(minHeight: 2),
              ),
            ],
            if (showServerStatus && reachabilityPhase == ReachabilityPhase.offline) ...[
              const SizedBox(height: 8),
              _StatusRow(
                icon: Icons.cloud_off_outlined,
                message: 'timeline_source_server_offline'.t(context: context),
              ),
            ],
            if (showGalleryStatus && galleryPermission.isLimited) ...[
              const SizedBox(height: 8),
              _StatusRow(
                icon: Icons.photo_library_outlined,
                message: 'timeline_source_limited_permission'.t(context: context),
                actionLabel: 'permission_onboarding_go_to_settings'.t(context: context),
                onAction: onManageGalleryPermission,
              ),
            ],
            if (showGalleryStatus && !galleryPermission.isGranted && !galleryPermission.isLimited) ...[
              const SizedBox(height: 8),
              _StatusRow(
                icon: Icons.no_photography_outlined,
                message: 'timeline_source_denied_permission'.t(context: context),
                actionLabel: 'permission_onboarding_go_to_settings'.t(context: context),
                onAction: onManageGalleryPermission,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.icon, required this.message, this.actionLabel, this.onAction});

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Icon(icon, size: 20, color: context.colorScheme.onSurfaceVariant),
      const SizedBox(width: 8),
      Expanded(
        child: Text(message, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant)),
      ),
      if (actionLabel != null && onAction != null) TextButton(onPressed: onAction, child: Text(actionLabel!)),
    ],
  );
}
