import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/remote_media.provider.dart';

class PartnerUserAvatar extends ConsumerWidget {
  const PartnerUserAvatar({super.key, required this.partner});

  final PartnerUserDto partner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = "${Store.get(StoreKey.serverEndpoint)}/users/${partner.id}/profile-image";
    final nameFirstLetter = partner.name.isNotEmpty ? partner.name[0] : "";
    return CircleAvatar(
      radius: 16,
      backgroundColor: context.primaryColor.withAlpha(50),
      foregroundImage: ref
          .watch(remoteImageProviderFactoryProvider)
          .image(url: url, edited: true, kind: MediaRequestKind.thumbnail),
      // silence errors if user has no profile image, use initials as fallback
      onForegroundImageError: (exception, stackTrace) {},
      child: Text(nameFirstLetter.toUpperCase()),
    );
  }
}
