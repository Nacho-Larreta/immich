import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/album/album_selector.widget.dart';
import 'package:immich_mobile/presentation/widgets/server/server_access_boundary.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';

@RoutePage()
class DriftAlbumsPage extends ConsumerStatefulWidget {
  const DriftAlbumsPage({super.key});

  @override
  ConsumerState<DriftAlbumsPage> createState() => _DriftAlbumsPageState();
}

class _DriftAlbumsPageState extends ConsumerState<DriftAlbumsPage> {
  final ScrollController _scrollController = ScrollController();

  Future<void> onRefresh() async {
    await ref.read(remoteAlbumProvider.notifier).refresh();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(serverAccessProvider);
    final viewerId = ref.watch(currentUserProvider.select((user) => user?.id));
    final canReadCache = access.allows(ServerCapability.cachedRead) && viewerId != null;
    final canMutate = access.allows(ServerCapability.remoteMutation);

    if (!canReadCache) {
      return Scaffold(
        body: CustomScrollView(
          slivers: [
            const ImmichSliverAppBar(snap: false, floating: false, pinned: true, showUploadButton: false),
            SliverFillRemaining(hasScrollBody: false, child: _ServerAccessNotice(access: access)),
          ],
        ),
      );
    }

    final albumCount = ref.watch(remoteAlbumProvider.select((state) => state.albums.length));
    final showScrollbar = albumCount > 20;

    final scrollView = CustomScrollView(
      controller: _scrollController,
      slivers: [
        ImmichSliverAppBar(
          snap: false,
          floating: false,
          pinned: true,
          actions: [
            if (canMutate)
              IconButton(
                onPressed: () => context.pushRoute(const DriftCreateAlbumRoute()),
                icon: const Icon(Icons.add_rounded),
              ),
          ],
          showUploadButton: false,
        ),
        if (!canMutate)
          SliverToBoxAdapter(
            child: _ServerAccessNotice(access: access, variant: ServerAccessNoticeVariant.section),
          ),
        AlbumSelector(
          canMutate: canMutate,
          onAlbumSelected: (album) {
            context.router.push(RemoteAlbumRoute(album: album));
          },
        ),
      ],
    );

    return RefreshIndicator(
      onRefresh: onRefresh,
      edgeOffset: 100,
      child: showScrollbar
          ? RawScrollbar(
              controller: _scrollController,
              interactive: true,
              thickness: 8,
              radius: const Radius.circular(4),
              thumbVisibility: false,
              thumbColor: context.colorScheme.primary,
              crossAxisMargin: 4,
              mainAxisMargin: 60,
              minThumbLength: 40,
              child: scrollView,
            )
          : scrollView,
    );
  }
}

class _ServerAccessNotice extends ConsumerWidget {
  const _ServerAccessNotice({required this.access, this.variant = ServerAccessNoticeVariant.fullPage});

  final ServerAccessPolicy access;
  final ServerAccessNoticeVariant variant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ServerAccessNotice(
      mode: access.mode,
      variant: variant,
      onConnect: () => context.pushRoute(const LoginRoute()),
      onReauthenticate: () => context.pushRoute(const LoginRoute()),
      onRetry: () => ref.read(serverReachabilityCoordinatorProvider).activateSession(),
    );
  }
}
