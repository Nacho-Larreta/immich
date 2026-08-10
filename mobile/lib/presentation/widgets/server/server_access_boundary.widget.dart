import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';

enum ServerAccessNoticeVariant { inline, section, fullPage }

class ServerCapabilityBoundary extends StatelessWidget {
  const ServerCapabilityBoundary({
    super.key,
    required this.access,
    required this.capability,
    required this.noticeVariant,
    required this.childBuilder,
    this.onConnect,
    this.onReauthenticate,
    this.onRetry,
  });

  final ServerAccessPolicy access;
  final ServerCapability capability;
  final ServerAccessNoticeVariant noticeVariant;
  final WidgetBuilder childBuilder;
  final VoidCallback? onConnect;
  final VoidCallback? onReauthenticate;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (access.allows(capability)) return childBuilder(context);
    return ServerAccessNotice(
      mode: access.mode,
      variant: noticeVariant,
      onConnect: onConnect,
      onReauthenticate: onReauthenticate,
      onRetry: onRetry,
    );
  }
}

class ServerAccessNotice extends StatelessWidget {
  const ServerAccessNotice({
    super.key,
    required this.mode,
    required this.variant,
    this.onConnect,
    this.onReauthenticate,
    this.onRetry,
  });

  final ServerAccessMode mode;
  final ServerAccessNoticeVariant variant;
  final VoidCallback? onConnect;
  final VoidCallback? onReauthenticate;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final content = _NoticeContent.forMode(
      mode,
      onConnect: onConnect,
      onReauthenticate: onReauthenticate,
      onRetry: onRetry,
    );
    final body = Semantics(
      container: true,
      liveRegion: true,
      label: content.semanticKey.t(context: context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: variant == ServerAccessNoticeVariant.inline
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Icon(content.icon, size: variant == ServerAccessNoticeVariant.fullPage ? 48 : 28),
          const SizedBox(height: 8),
          Text(content.titleKey.t(context: context), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(content.messageKey.t(context: context), textAlign: TextAlign.center),
          if (content.action case (final labelKey, final callback)) ...[
            const SizedBox(height: 8),
            TextButton(
              style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(44, 44))),
              onPressed: callback,
              child: Text(labelKey.t(context: context)),
            ),
          ],
        ],
      ),
    );

    return switch (variant) {
      ServerAccessNoticeVariant.inline => Padding(padding: const EdgeInsets.all(12), child: body),
      ServerAccessNoticeVariant.section => Card(
        margin: const EdgeInsets.all(16),
        child: Padding(padding: const EdgeInsets.all(16), child: body),
      ),
      ServerAccessNoticeVariant.fullPage => SafeArea(
        child: Center(
          child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: body),
        ),
      ),
    };
  }
}

final class _NoticeContent {
  const _NoticeContent({
    required this.icon,
    required this.titleKey,
    required this.messageKey,
    required this.semanticKey,
    this.action,
  });

  final IconData icon;
  final String titleKey;
  final String messageKey;
  final String semanticKey;
  final (String, VoidCallback)? action;

  factory _NoticeContent.forMode(
    ServerAccessMode mode, {
    VoidCallback? onConnect,
    VoidCallback? onReauthenticate,
    VoidCallback? onRetry,
  }) => switch (mode) {
    ServerAccessMode.unconfigured => _NoticeContent(
      icon: Icons.cloud_outlined,
      titleKey: 'server_access_unconfigured_title',
      messageKey: 'server_access_unconfigured_message',
      semanticKey: 'server_access_unconfigured_semantic',
      action: onConnect == null ? null : ('server_access_connect', onConnect),
    ),
    ServerAccessMode.reauthenticationRequired => _NoticeContent(
      icon: Icons.lock_reset_outlined,
      titleKey: 'server_access_reauthentication_title',
      messageKey: 'server_access_reauthentication_message',
      semanticKey: 'server_access_reauthentication_semantic',
      action: onReauthenticate == null ? null : ('server_access_reauthenticate', onReauthenticate),
    ),
    ServerAccessMode.probing => const _NoticeContent(
      icon: Icons.sync,
      titleKey: 'server_access_probing_title',
      messageKey: 'server_access_probing_message',
      semanticKey: 'server_access_probing_semantic',
    ),
    ServerAccessMode.offline => _NoticeContent(
      icon: Icons.cloud_off_outlined,
      titleKey: 'server_access_offline_title',
      messageKey: 'server_access_offline_message',
      semanticKey: 'server_access_offline_semantic',
      action: onRetry == null ? null : ('server_access_retry', onRetry),
    ),
    ServerAccessMode.online => const _NoticeContent(
      icon: Icons.cloud_done_outlined,
      titleKey: 'server_access_online_title',
      messageKey: 'server_access_online_message',
      semanticKey: 'server_access_online_semantic',
    ),
  };
}
