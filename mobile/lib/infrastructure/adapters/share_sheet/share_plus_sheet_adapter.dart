import 'dart:async';
import 'dart:ui';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/share_sheet.interface.dart';
import 'package:immich_mobile/domain/models/share.model.dart' as domain;
import 'package:share_plus/share_plus.dart' as plugin;

typedef SharePlusInvoker = Future<plugin.ShareResult> Function(List<plugin.XFile> files, Rect? anchor);

final class SharePlusSheetAdapter implements ShareSheetPort {
  const SharePlusSheetAdapter({SharePlusInvoker invoker = _invoke}) : _invoker = invoker;

  final SharePlusInvoker _invoker;

  @override
  CancellableRequest<domain.ShareResult> share(domain.ShareSheetRequest request) {
    return _SharePlusOperation(request, _invoker);
  }

  static Future<plugin.ShareResult> _invoke(List<plugin.XFile> files, Rect? anchor) {
    return plugin.Share.shareXFiles(files, sharePositionOrigin: anchor);
  }
}

final class _SharePlusOperation implements CancellableRequest<domain.ShareResult> {
  _SharePlusOperation(domain.ShareSheetRequest request, SharePlusInvoker invoker)
    : _result = _present(request, invoker);

  final Future<domain.ShareResult> _result;

  @override
  Future<domain.ShareResult> get result => _result;

  @override
  Future<void> cancel() async {
    // A platform share sheet cannot be recalled after ownership is transferred.
  }

  static Future<domain.ShareResult> _present(domain.ShareSheetRequest request, SharePlusInvoker invoker) async {
    try {
      final result = await invoker(
        request.paths.map(plugin.XFile.new).toList(growable: false),
        switch (request.anchor) {
          final anchor? => Rect.fromLTWH(anchor.x, anchor.y, anchor.width, anchor.height),
          null => null,
        },
      );
      final disposition = switch (result.status) {
        plugin.ShareResultStatus.success => domain.ShareDisposition.completed,
        plugin.ShareResultStatus.dismissed => domain.ShareDisposition.dismissed,
        plugin.ShareResultStatus.unavailable => domain.ShareDisposition.unknown,
      };
      return domain.ShareResult.success(actualCount: request.paths.length, disposition: disposition);
    } on Object {
      return const domain.ShareResult.failure(
        domain.ShareSheetFailure(error: domain.ShareSheetError.presentationFailed),
      );
    }
  }
}
