import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/remote_media.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';

class AssetMarkerIcon extends ConsumerWidget {
  const AssetMarkerIcon({required this.id, required this.thumbhash, super.key});

  final String id;
  final String thumbhash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageUrl = getThumbnailUrlForRemoteId(id);
    return LayoutBuilder(
      builder: (context, constraints) {
        final pinHeight = constraints.maxHeight * 0.14;
        final pinWidth = constraints.maxWidth * 0.14;
        return SizedOverflowBox(
          size: Size(pinWidth, pinHeight),
          child: Stack(
            // alignment: AlignmentGeometry.center,
            children: [
              Positioned(
                bottom: 0,
                left: constraints.maxWidth * 0.5,
                child: CustomPaint(
                  painter: _PinPainter(
                    primaryColor: context.colorScheme.onSurface,
                    secondaryColor: context.colorScheme.surface,
                    primaryRadius: constraints.maxHeight * 0.06,
                    secondaryRadius: constraints.maxHeight * 0.038,
                  ),
                  child: SizedBox(height: pinHeight, width: pinWidth),
                ),
              ),
              Positioned(
                top: constraints.maxHeight * 0.07,
                left: constraints.maxWidth * 0.17,
                child: CircleAvatar(
                  radius: constraints.maxHeight * 0.40,
                  backgroundColor: context.colorScheme.onSurface,
                  child: CircleAvatar(
                    radius: constraints.maxHeight * 0.37,
                    backgroundImage: ref
                        .watch(remoteImageProviderFactoryProvider)
                        .image(url: imageUrl, edited: true, kind: MediaRequestKind.thumbnail),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PinPainter extends CustomPainter {
  final Color primaryColor;
  final Color secondaryColor;
  final double primaryRadius;
  final double secondaryRadius;

  const _PinPainter({
    required this.primaryColor,
    required this.secondaryColor,
    required this.primaryRadius,
    required this.secondaryRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    Paint primaryBrush = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;

    Paint secondaryBrush = Paint()
      ..color = secondaryColor
      ..style = PaintingStyle.fill;

    Paint lineBrush = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(Offset(size.width / 2, size.height), primaryRadius, primaryBrush);
    canvas.drawCircle(Offset(size.width / 2, size.height), secondaryRadius, secondaryBrush);
    canvas.drawPath(getTrianglePath(size.width, size.height), primaryBrush);
    // The line is to make the above triangluar path more prominent since it has a slight curve
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), lineBrush);
  }

  Path getTrianglePath(double x, double y) {
    final firstEndPoint = Offset(x / 2, y);
    final controlPoint = Offset(x / 2, y * 0.3);
    final secondEndPoint = Offset(x, 0);

    return Path()
      ..quadraticBezierTo(controlPoint.dx, controlPoint.dy, firstEndPoint.dx, firstEndPoint.dy)
      ..quadraticBezierTo(controlPoint.dx, controlPoint.dy, secondEndPoint.dx, secondEndPoint.dy)
      ..lineTo(0, 0);
  }

  @override
  bool shouldRepaint(_PinPainter old) {
    return old.primaryColor != primaryColor || old.secondaryColor != secondaryColor;
  }
}
