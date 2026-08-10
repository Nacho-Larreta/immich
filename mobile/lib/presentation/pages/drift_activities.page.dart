import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/like_activity_action_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/album/drift_activity_text_field.dart';
import 'package:immich_mobile/presentation/widgets/album/remote_album_scope_boundary.widget.dart';
import 'package:immich_mobile/presentation/widgets/server/server_access_boundary.widget.dart';
import 'package:immich_mobile/providers/activity.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/activities/comment_bubble.dart';

@RoutePage()
class DriftActivitiesPage extends ConsumerWidget {
  final RemoteAlbum album;
  final String? assetId;
  final String? assetName;

  const DriftActivitiesPage({super.key, required this.album, this.assetId, this.assetName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(serverAccessProvider);
    if (!access.allows(ServerCapability.remoteRead)) {
      return _UnavailableActivities(access: access);
    }

    return RemoteAlbumScopeBoundary(
      albumId: album.id,
      loadingBuilder: (_) => const Scaffold(body: Center(child: CircularProgressIndicator.adaptive())),
      unavailableBuilder: (_) => _UnavailableActivities(access: access),
      builder: (_, scope, resolvedAlbum) => _ResolvedActivitiesPage(
        album: resolvedAlbum,
        scope: scope,
        assetId: assetId,
        assetName: assetName,
        canMutate: access.allows(ServerCapability.remoteMutation),
      ),
    );
  }
}

class _ResolvedActivitiesPage extends HookConsumerWidget {
  const _ResolvedActivitiesPage({
    required this.album,
    required this.scope,
    required this.assetId,
    required this.assetName,
    required this.canMutate,
  });

  final RemoteAlbum album;
  final RemoteAlbumScope scope;
  final String? assetId;
  final String? assetName;
  final bool canMutate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activityScope = RemoteAlbumActivityScope(album: scope, assetId: assetId);
    final activityNotifier = ref.read(albumActivityProvider(activityScope).notifier);
    final activities = ref.watch(albumActivityProvider(activityScope));
    final listViewScrollController = useScrollController();

    void scrollToBottom() {
      listViewScrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.fastOutSlowIn);
    }

    Future<void> onAddComment(String comment) async {
      await activityNotifier.addComment(comment);
      scrollToBottom();
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(album.name),
            if (assetName != null) Text(assetName!, style: context.textTheme.bodySmall),
          ],
        ),
        actions: canMutate ? [const LikeActivityActionButton(iconOnly: true)] : null,
        actionsPadding: const EdgeInsets.only(right: 8),
      ),
      body: activities.widgetWhen(
        onData: (data) {
          final List<Widget> activityWidgets = [];
          for (final activity in data.reversed) {
            activityWidgets.add(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: CommentBubble(activity: activity, isAssetActivity: assetId != null),
              ),
            );
          }

          return SafeArea(
            child: Stack(
              children: [
                ListView(
                  controller: listViewScrollController,
                  padding: const EdgeInsets.only(top: 8, bottom: 80),
                  reverse: true,
                  children: activityWidgets,
                ),
                if (canMutate)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      decoration: BoxDecoration(
                        color: context.scaffoldBackgroundColor,
                        border: Border(top: BorderSide(color: context.colorScheme.secondaryContainer, width: 1)),
                      ),
                      child: DriftActivityTextField(isEnabled: album.isActivityEnabled, onSubmit: onAddComment),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
      resizeToAvoidBottomInset: true,
    );
  }
}

class _UnavailableActivities extends ConsumerWidget {
  const _UnavailableActivities({required this.access});

  final ServerAccessPolicy access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: ServerAccessNotice(
        mode: access.mode,
        variant: ServerAccessNoticeVariant.fullPage,
        onConnect: () => context.pushRoute(const LoginRoute()),
        onReauthenticate: () => context.pushRoute(const LoginRoute()),
        onRetry: () => ref.read(serverReachabilityCoordinatorProvider).activateSession(),
      ),
    );
  }
}
