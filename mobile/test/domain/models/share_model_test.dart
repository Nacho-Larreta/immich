import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';
import 'package:immich_mobile/domain/models/share.model.dart';

void main() {
  group('ShareSheetRequest', () {
    test('defensively copies paths and has value semantics', () {
      final paths = ['/tmp/one.jpg', '/tmp/two.mov'];
      final anchor = ShareAnchor(x: 0, y: 0, width: 320, height: 640);

      final request = ShareSheetRequest(paths: paths, anchor: anchor);
      paths.add('/tmp/three.heic');

      expect(request.paths, ['/tmp/one.jpg', '/tmp/two.mov']);
      expect(request, ShareSheetRequest(paths: const ['/tmp/one.jpg', '/tmp/two.mov'], anchor: anchor));
    });

    test('rejects empty path collections and blank paths', () {
      expect(() => ShareSheetRequest(paths: const []), throwsArgumentError);
      expect(() => ShareSheetRequest(paths: const ['/tmp/one.jpg', '  ']), throwsArgumentError);
    });
  });

  group('ShareAnchor', () {
    test('rejects non-finite coordinates and non-positive dimensions', () {
      expect(() => ShareAnchor(x: double.nan, y: 0, width: 1, height: 1), throwsArgumentError);
      expect(() => ShareAnchor(x: 0, y: 0, width: 0, height: 1), throwsArgumentError);
      expect(() => ShareAnchor(x: 0, y: 0, width: 1, height: -1), throwsArgumentError);
    });
  });

  group('ShareResult', () {
    test('success requires a positive actual count and records disposition', () {
      expect(
        ShareResult.success(actualCount: 2, disposition: ShareDisposition.completed),
        ShareResult.success(actualCount: 2, disposition: ShareDisposition.completed),
      );
      expect(() => ShareResult.success(actualCount: 0, disposition: ShareDisposition.unknown), throwsArgumentError);
    });

    test('asset failures identify the asset, phase, and typed export error', () {
      final failure = ShareAssetFailure(
        assetId: 'asset-1',
        phase: SharePhase.localExport,
        error: OriginalExportError.mediaNotLocal,
      );

      expect(ShareResult.failure(failure), ShareResult.failure(failure));
      expect(
        failure,
        ShareAssetFailure(assetId: 'asset-1', phase: SharePhase.localExport, error: OriginalExportError.mediaNotLocal),
      );
    });

    test('sheet failures identify the presentation phase without inventing an asset', () {
      const failure = ShareSheetFailure(error: ShareSheetError.presentationFailed);

      expect(failure.phase, SharePhase.presentation);
      expect(const ShareResult.failure(failure), const ShareResult.failure(failure));
    });
  });
}
