import 'package:immich_mobile/domain/models/original_export.model.dart';

enum ShareDisposition { completed, dismissed, unknown }

enum SharePhase { localExport, remoteExport, presentation, cleanup }

enum ShareSheetError { unavailable, presentationFailed }

final class ShareProgress {
  ShareProgress({required this.phase, required this.completedCount, required this.totalCount}) {
    if (completedCount < 0 || totalCount <= 0 || completedCount > totalCount) {
      throw ArgumentError('Share progress must satisfy 0 <= completedCount <= totalCount');
    }
  }

  final SharePhase phase;
  final int completedCount;
  final int totalCount;

  @override
  bool operator ==(Object other) {
    return other is ShareProgress &&
        other.phase == phase &&
        other.completedCount == completedCount &&
        other.totalCount == totalCount;
  }

  @override
  int get hashCode => Object.hash(phase, completedCount, totalCount);
}

final class ShareAnchor {
  ShareAnchor({required this.x, required this.y, required this.width, required this.height}) {
    _validateFinite(x, 'x');
    _validateFinite(y, 'y');
    _validatePositiveFinite(width, 'width');
    _validatePositiveFinite(height, 'height');
  }

  final double x;
  final double y;
  final double width;
  final double height;

  @override
  bool operator ==(Object other) {
    return other is ShareAnchor && other.x == x && other.y == y && other.width == width && other.height == height;
  }

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

final class ShareSheetRequest {
  ShareSheetRequest({required Iterable<String> paths, this.anchor}) : paths = List.unmodifiable(paths) {
    if (this.paths.isEmpty) {
      throw ArgumentError.value(this.paths, 'paths', 'Must not be empty');
    }
    if (this.paths.any((path) => path.trim().isEmpty)) {
      throw ArgumentError.value(this.paths, 'paths', 'Must contain only non-empty paths');
    }
  }

  final List<String> paths;
  final ShareAnchor? anchor;

  @override
  bool operator ==(Object other) {
    return other is ShareSheetRequest && _listsEqual(other.paths, paths) && other.anchor == anchor;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(paths), anchor);
}

sealed class ShareFailureDetail {
  const ShareFailureDetail();

  SharePhase get phase;
}

final class ShareAssetFailure extends ShareFailureDetail {
  ShareAssetFailure({required this.assetId, required this.phase, required this.error}) {
    if (assetId.trim().isEmpty) {
      throw ArgumentError.value(assetId, 'assetId', 'Must not be empty');
    }
    if (phase == SharePhase.presentation) {
      throw ArgumentError.value(phase, 'phase', 'Presentation failures are not asset-specific');
    }
  }

  final String assetId;
  @override
  final SharePhase phase;
  final OriginalExportError error;

  @override
  bool operator ==(Object other) {
    return other is ShareAssetFailure && other.assetId == assetId && other.phase == phase && other.error == error;
  }

  @override
  int get hashCode => Object.hash(assetId, phase, error);
}

final class ShareSheetFailure extends ShareFailureDetail {
  const ShareSheetFailure({required this.error});

  final ShareSheetError error;

  @override
  SharePhase get phase => SharePhase.presentation;

  @override
  bool operator ==(Object other) => other is ShareSheetFailure && other.error == error;

  @override
  int get hashCode => error.hashCode;
}

sealed class ShareResult {
  const ShareResult();

  factory ShareResult.success({required int actualCount, required ShareDisposition disposition}) =
      SuccessfulShareResult;
  const factory ShareResult.failure(ShareFailureDetail error) = FailedShareResult;
}

final class SuccessfulShareResult extends ShareResult {
  SuccessfulShareResult({required this.actualCount, required this.disposition}) {
    if (actualCount <= 0) {
      throw ArgumentError.value(actualCount, 'actualCount', 'Must be positive');
    }
  }

  final int actualCount;
  final ShareDisposition disposition;

  @override
  bool operator ==(Object other) {
    return other is SuccessfulShareResult && other.actualCount == actualCount && other.disposition == disposition;
  }

  @override
  int get hashCode => Object.hash(actualCount, disposition);
}

final class FailedShareResult extends ShareResult {
  const FailedShareResult(this.error);

  final ShareFailureDetail error;

  @override
  bool operator ==(Object other) => other is FailedShareResult && other.error == error;

  @override
  int get hashCode => error.hashCode;
}

void _validateFinite(double value, String argumentName) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, argumentName, 'Must be finite');
  }
}

void _validatePositiveFinite(double value, String argumentName) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, argumentName, 'Must be positive and finite');
  }
}

bool _listsEqual(List<String> first, List<String> second) {
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}
