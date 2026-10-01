import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/manual_upload.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_ui/immich_ui.dart';

class UploadActionButton extends ConsumerWidget {
  final ActionSource source;
  final bool iconOnly;
  final bool menuItem;

  const UploadActionButton({super.key, required this.source, this.iconOnly = false, this.menuItem = false});

  void _onTap(BuildContext context, WidgetRef ref) async {
    if (!context.mounted) {
      return;
    }

    List<LocalAsset>? assets;

    if (source == ActionSource.timeline) {
      assets = ref.read(multiSelectProvider).selectedAssets.whereType<LocalAsset>().toList();
      if (assets.isEmpty) {
        return;
      }
    }

    final upload = ref.read(actionProvider.notifier).upload(source, assets: assets);
    if (!CurrentPlatform.isIOS && source == ActionSource.viewer && context.mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _ForegroundUploadDialog(result: upload),
        ),
      );
    }
    final result = await upload;
    final committed = CurrentPlatform.isIOS ? result.acceptedCount == assets?.length : result.success;
    if (source == ActionSource.timeline && committed) {
      ref.read(multiSelectProvider.notifier).deselectAssets(assets!);
    }

    if (CurrentPlatform.isIOS && source == ActionSource.viewer && result.acceptedCount > 0 && context.mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: true,
          builder: (_) =>
              QueuedUploadDialog(intentIds: result.acceptedIntentIds, localAssetIds: result.acceptedLocalAssetIds),
        ),
      );
    }

    if (context.mounted && !result.success) {
      ImmichToast.show(
        context: context,
        msg: 'scaffold_body_error_occurred'.t(context: context),
        gravity: ToastGravity.BOTTOM,
        toastType: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BaseActionButton(
      iconData: Icons.backup_outlined,
      label: "upload".t(context: context),
      iconOnly: iconOnly,
      menuItem: menuItem,
      onPressed: () => _onTap(context, ref),
    );
  }
}

class _ForegroundUploadDialog extends ConsumerStatefulWidget {
  const _ForegroundUploadDialog({required this.result});

  final Future<ActionResult> result;

  @override
  ConsumerState<_ForegroundUploadDialog> createState() => _ForegroundUploadDialogState();
}

class _ForegroundUploadDialogState extends ConsumerState<_ForegroundUploadDialog> {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.result.whenComplete(() {
        if (mounted && !_dismissed) {
          _dismissed = true;
          Navigator.of(context).pop();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final progressMap = ref.watch(assetUploadProgressProvider);
    final values = progressMap.values.where((value) => value >= 0).toList();
    final progress = values.isEmpty ? 0.0 : values.reduce((sum, value) => sum + value) / values.length;
    final hasError = progressMap.values.any((value) => value < 0);

    return AlertDialog(
      title: Text('uploading'.t(context: context)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasError)
            const Icon(Icons.error_outline, color: Colors.red, size: 48)
          else
            CircularProgressIndicator(value: progress > 0 ? progress : null),
          const SizedBox(height: 16),
          Text(hasError ? 'Error' : '${(progress * 100).toInt()}%'),
        ],
      ),
      actions: [
        ImmichTextButton(
          onPressed: () {
            final token = ref.read(manualUploadCancelTokenProvider);
            if (token != null && !token.isCompleted) token.complete();
            _dismissed = true;
            Navigator.of(context).pop();
          },
          labelText: 'cancel'.t(context: context),
        ),
      ],
    );
  }
}

class QueuedUploadDialog extends ConsumerWidget {
  const QueuedUploadDialog({super.key, required this.intentIds, required this.localAssetIds});

  final List<String> intentIds;
  final List<String> localAssetIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(assetUploadProgressProvider);
    final values = [
      for (final id in localAssetIds)
        if (progress[id] case final value?) value,
    ];
    final active = values.isNotEmpty;
    final percentage = active ? (values.reduce((sum, value) => sum + value) / values.length * 100).toInt() : 0;

    return AlertDialog(
      title: Text('uploading'.t(context: context)),
      content: active
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(value: percentage > 0 ? percentage / 100 : null),
                const SizedBox(height: 16),
                Text('$percentage%'),
              ],
            )
          : const SizedBox.shrink(),
      actions: [
        ImmichTextButton(
          onPressed: () => Navigator.of(context).pop(),
          labelText: 'close'.t(context: context),
        ),
        if (active)
          ImmichTextButton(
            onPressed: () async {
              try {
                for (final id in intentIds) {
                  await ref.read(manualUploadSubmissionProvider).requestCancel(id);
                }
                if (context.mounted) Navigator.of(context).pop();
              } on Object {
                if (context.mounted) {
                  ImmichToast.show(
                    context: context,
                    msg: 'scaffold_body_error_occurred'.t(context: context),
                    gravity: ToastGravity.BOTTOM,
                    toastType: ToastType.error,
                  );
                }
              }
            },
            labelText: 'cancel'.t(context: context),
          ),
      ],
    );
  }
}
