import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/remote_media.provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/widgets/search/thumbnail_with_info_container.dart';

class ThumbnailWithInfo extends ConsumerWidget {
  const ThumbnailWithInfo({
    super.key,
    required this.textInfo,
    this.imageUrl,
    this.noImageIcon,
    this.borderRadius = 10,
    this.onTap,
  });

  final String textInfo;
  final String? imageUrl;
  final VoidCallback? onTap;
  final IconData? noImageIcon;
  final double borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var textAndIconColor = context.isDarkTheme ? Colors.grey[100] : Colors.grey[700];
    return ThumbnailWithInfoContainer(
      onTap: onTap,
      borderRadius: borderRadius,
      label: textInfo,
      child: imageUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: Thumbnail(
                imageProvider: ref
                    .watch(remoteImageProviderFactoryProvider)
                    .image(url: imageUrl!, edited: true, kind: MediaRequestKind.thumbnail),
              ),
            )
          : Center(child: Icon(noImageIcon ?? Icons.not_listed_location, color: textAndIconColor)),
    );
  }
}
