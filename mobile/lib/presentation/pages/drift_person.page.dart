import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/people/person_option_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/server/server_access_boundary.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/people.utils.dart';
import 'package:immich_mobile/widgets/common/person_sliver_app_bar.dart';

@RoutePage()
class DriftPersonPage extends ConsumerStatefulWidget {
  final DriftPerson person;

  const DriftPersonPage({super.key, required this.person});

  @override
  ConsumerState<DriftPersonPage> createState() => _DriftPersonPageState();
}

class _DriftPersonPageState extends ConsumerState<DriftPersonPage> {
  late DriftPerson _person;

  @override
  initState() {
    super.initState();
    _person = widget.person;
  }

  Future<void> handleEditName(BuildContext context) async {
    final newName = await showNameEditModal(context, _person);

    if (newName != null && newName.isNotEmpty) {
      setState(() {
        _person = _person.copyWith(name: newName);
      });
    }
  }

  Future<void> handleEditBirthday(BuildContext context) async {
    final birthday = await showBirthdayEditModal(context, _person);

    if (birthday != null) {
      setState(() {
        _person = _person.copyWith(birthDate: birthday);
      });
    }
  }

  void showOptionSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.colorScheme.surface,
      isScrollControlled: false,
      builder: (context) {
        return PersonOptionSheet(
          onEditName: () async {
            await handleEditName(context);
            ContextHelper(context).pop();
          },
          onEditBirthday: () async {
            await handleEditBirthday(context);
            ContextHelper(context).pop();
          },
          birthdayExists: _person.birthDate != null,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(serverAccessProvider);
    final user = ref.watch(currentUserProvider);
    final hasScopedIdentity = user != null && user.id == _person.ownerId;
    final canReadCache = access.allows(ServerCapability.cachedRead) && hasScopedIdentity;
    final canMutate = access.allows(ServerCapability.remoteMutation);

    if (!canReadCache) {
      final noticeMode = access.mode == ServerAccessMode.online
          ? ServerAccessMode.reauthenticationRequired
          : access.mode;
      return Scaffold(
        body: ServerAccessNotice(
          mode: noticeMode,
          variant: ServerAccessNoticeVariant.fullPage,
          onConnect: () => context.pushRoute(const LoginRoute()),
          onReauthenticate: () => context.pushRoute(const LoginRoute()),
          onRetry: () => ref.read(serverReachabilityCoordinatorProvider).activateSession(),
        ),
      );
    }

    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          final user = ref.watch(currentUserProvider);
          if (user == null) {
            throw Exception('User must be logged in to view person timeline');
          }

          final timelineService = ref.watch(timelineFactoryProvider).person(user.id, _person.id);
          ref.onDispose(timelineService.dispose);
          return timelineService;
        }),
      ],
      child: Timeline(
        topSliverWidget: !canMutate
            ? SliverToBoxAdapter(
                child: ServerAccessNotice(
                  mode: access.mode,
                  variant: ServerAccessNoticeVariant.inline,
                  onReauthenticate: () => context.pushRoute(const LoginRoute()),
                  onRetry: () => ref.read(serverReachabilityCoordinatorProvider).activateSession(),
                ),
              )
            : null,
        appBar: PersonSliverAppBar(
          person: _person,
          onNameTap: canMutate ? () => handleEditName(context) : null,
          onBirthdayTap: canMutate ? () => handleEditBirthday(context) : null,
          onShowOptions: canMutate ? () => showOptionSheet(context) : null,
        ),
      ),
    );
  }
}
