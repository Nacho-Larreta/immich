import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/interfaces/share_operation.interface.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';
import 'package:immich_mobile/domain/models/share.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';

enum _ShareDialogExit { completed, presentation, cancelled }

class SharePreparingDialog extends StatefulWidget {
  const SharePreparingDialog({super.key, required this.operation});

  final ShareOperation operation;

  @override
  State<SharePreparingDialog> createState() => _SharePreparingDialogState();
}

class _SharePreparingDialogState extends State<SharePreparingDialog> {
  StreamSubscription<ShareProgress>? _progressSubscription;
  ShareProgress? _progress;
  bool _cancelRequested = false;
  bool _exited = false;

  @override
  void initState() {
    super.initState();
    _progressSubscription = widget.operation.progress.listen((progress) {
      if (!mounted) {
        return;
      }
      if (progress.phase == SharePhase.presentation) {
        _exitOnce(_ShareDialogExit.presentation);
        return;
      }
      setState(() => _progress = progress);
    });
    widget.operation.result.then((_) {
      if (mounted) {
        _exitOnce(_ShareDialogExit.completed);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_progressSubscription?.cancel());
    super.dispose();
  }

  void _cancel() {
    if (_cancelRequested) {
      return;
    }
    _cancelRequested = true;
    unawaited(widget.operation.cancel());
    _exitOnce(_ShareDialogExit.cancelled);
  }

  void _exitOnce(_ShareDialogExit exit) {
    if (_exited || !mounted) {
      return;
    }
    _exited = true;
    Navigator.of(context).pop(exit);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          Container(margin: const EdgeInsets.only(top: 12), child: const Text('share_dialog_preparing').tr()),
          if (progress != null) Text('${progress.completedCount}/${progress.totalCount}'),
        ],
      ),
      actions: [TextButton(onPressed: _cancel, child: const Text('cancel').tr())],
    );
  }
}

class ShareActionButton extends ConsumerWidget {
  final ActionSource source;
  final bool iconOnly;
  final bool menuItem;

  const ShareActionButton({super.key, required this.source, this.iconOnly = false, this.menuItem = false});

  Future<void> _onTap(BuildContext context, WidgetRef ref) async {
    if (!context.mounted) {
      return;
    }

    final size = context.sizeData;
    final operation = ref
        .read(actionProvider.notifier)
        .shareAssets(
          source,
          anchor: ShareAnchor(x: 0, y: 0, width: size.width / 3, height: size.height),
        );
    final dialogExit = await showDialog<_ShareDialogExit>(
      context: context,
      builder: (_) => SharePreparingDialog(operation: operation),
      barrierDismissible: false,
      useRootNavigator: false,
    );
    final result = await operation.result;
    if (!context.mounted) {
      return;
    }

    if (dialogExit == _ShareDialogExit.cancelled || _isCancelled(result)) {
      return;
    }
    if (result case SuccessfulShareResult(:final actualCount)) {
      if (actualCount > 0) {
        ref.read(multiSelectProvider.notifier).reset();
      }
      return;
    }

    ImmichToast.show(
      context: context,
      msg: _failureMessageKey((result as FailedShareResult).error).t(context: context),
      gravity: ToastGravity.BOTTOM,
      toastType: ToastType.error,
    );
  }

  static bool _isCancelled(ShareResult result) {
    return result is FailedShareResult &&
        result.error is ShareAssetFailure &&
        (result.error as ShareAssetFailure).error == OriginalExportError.cancelled;
  }

  static String _failureMessageKey(ShareFailureDetail failure) {
    if (failure case ShareAssetFailure(:final error)) {
      return switch (error) {
        OriginalExportError.mediaNotLocal || OriginalExportError.iCloudUnavailable => 'asset_not_found_on_icloud',
        OriginalExportError.assetMissing ||
        OriginalExportError.cancelled ||
        OriginalExportError.timeout ||
        OriginalExportError.unauthorized ||
        OriginalExportError.wrongServer ||
        OriginalExportError.serverUnavailable ||
        OriginalExportError.httpFailure ||
        OriginalExportError.storageUnavailable ||
        OriginalExportError.writeFailed ||
        OriginalExportError.cleanupFailed => 'scaffold_body_error_occurred',
        OriginalExportError.leaseNotFound || OriginalExportError.platformUnsupported => 'scaffold_body_error_occurred',
      };
    }
    return 'scaffold_body_error_occurred';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BaseActionButton(
      iconData: Platform.isAndroid ? Icons.share_rounded : Icons.ios_share_rounded,
      label: 'share'.t(context: context),
      iconOnly: iconOnly,
      menuItem: menuItem,
      onPressed: () => _onTap(context, ref),
    );
  }
}
