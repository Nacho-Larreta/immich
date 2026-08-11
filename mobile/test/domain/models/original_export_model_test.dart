import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';

void main() {
  test('remote context binding is immutable and binds the complete authorization proof', () {
    final binding = OriginalExportContextBinding(
      sessionEpoch: 7,
      expectedContextGeneration: 19,
      apiEndpoint: Uri.parse('http://photos.test:2283/api'),
      exactOrigin: Uri.parse('http://photos.test:2283'),
      schemePolicy: EndpointSchemePolicy.registeredLocalHttp,
    );

    expect(binding.sessionEpoch, 7);
    expect(binding.expectedContextGeneration, 19);
    expect(binding.apiEndpoint, Uri.parse('http://photos.test:2283/api'));
    expect(binding.exactOrigin, Uri.parse('http://photos.test:2283'));
    expect(binding.schemePolicy, EndpointSchemePolicy.registeredLocalHttp);
  });

  test('stale context is a distinct native terminal', () {
    expect(OriginalExportError.staleContext.name, 'staleContext');
  });

  group('LocalOriginalExportRequest', () {
    test('has value semantics', () {
      final first = LocalOriginalExportRequest(
        assetId: 'asset-1',
        suggestedFilename: 'IMG_0001.HEIC',
        policy: LocalOriginalExportPolicy.localOnly,
      );
      final second = LocalOriginalExportRequest(
        assetId: 'asset-1',
        suggestedFilename: 'IMG_0001.HEIC',
        policy: LocalOriginalExportPolicy.localOnly,
      );

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('rejects empty asset identifiers and filenames', () {
      expect(
        () => LocalOriginalExportRequest(
          assetId: '   ',
          suggestedFilename: 'IMG_0001.HEIC',
          policy: LocalOriginalExportPolicy.localOnly,
        ),
        throwsArgumentError,
      );
      expect(
        () => LocalOriginalExportRequest(
          assetId: 'asset-1',
          suggestedFilename: '',
          policy: LocalOriginalExportPolicy.localOnly,
        ),
        throwsArgumentError,
      );
    });
  });

  group('RemoteOriginalExportRequest', () {
    test('preserves the exact HTTP resource URI and has value semantics', () {
      final resource = Uri.parse('https://photos.example/api/assets/asset-1/original?edited=false');
      final first = RemoteOriginalExportRequest(resource: resource, suggestedFilename: 'IMG_0001.HEIC');
      final second = RemoteOriginalExportRequest(resource: resource, suggestedFilename: 'IMG_0001.HEIC');

      expect(first.resource, same(resource));
      expect(first.origin, Uri.parse('https://photos.example'));
      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('rejects relative and non-HTTP resource URIs', () {
      expect(
        () => RemoteOriginalExportRequest(
          resource: Uri.parse('/api/assets/asset-1/original'),
          suggestedFilename: 'IMG_0001.HEIC',
        ),
        throwsArgumentError,
      );
      expect(
        () => RemoteOriginalExportRequest(
          resource: Uri.parse('file:///tmp/IMG_0001.HEIC'),
          suggestedFilename: 'IMG_0001.HEIC',
        ),
        throwsArgumentError,
      );
    });
  });

  group('OriginalExportResult', () {
    test('success owns a caller-releasable temporary file lease', () {
      final lease = _RecordingLease();

      final result = OriginalExportResult.success(lease);

      expect(result, OriginalExportResult.success(lease));
      expect(result.leaseOrNull, same(lease));
      expect(result.errorOrNull, isNull);
    });

    test('rejects a success whose lease is not owned by the caller', () {
      final borrowedLease = _RecordingLease(ownership: TemporaryFileOwnership.external);

      expect(() => OriginalExportResult.success(borrowedLease), throwsArgumentError);
    });

    test('failure exposes every typed export error without string exceptions', () {
      for (final error in OriginalExportError.values) {
        final result = OriginalExportResult.failure(error);

        expect(result, OriginalExportResult.failure(error));
        expect(result.errorOrNull, error);
        expect(result.leaseOrNull, isNull);
      }

      expect(OriginalExportError.values, [
        OriginalExportError.assetMissing,
        OriginalExportError.mediaNotLocal,
        OriginalExportError.iCloudUnavailable,
        OriginalExportError.cancelled,
        OriginalExportError.staleContext,
        OriginalExportError.timeout,
        OriginalExportError.unauthorized,
        OriginalExportError.wrongServer,
        OriginalExportError.serverUnavailable,
        OriginalExportError.httpFailure,
        OriginalExportError.storageUnavailable,
        OriginalExportError.writeFailed,
        OriginalExportError.cleanupFailed,
        OriginalExportError.leaseNotFound,
        OriginalExportError.platformUnsupported,
      ]);
    });
  });

  test('temporary file release is asynchronous, concurrent-safe, and idempotent', () async {
    final lease = _RecordingLease();

    await Future.wait([lease.release(), lease.release(), lease.release()]);
    await lease.release();

    expect(lease.releaseCount, 1);
    expect(lease.isReleased, isTrue);
  });

  test('failed temporary file release is attempted once and remains unreleased', () async {
    final failure = StateError('cleanup failed');
    final lease = _FailingLease(failure);

    final firstRelease = lease.release();
    final concurrentRelease = lease.release();

    expect(concurrentRelease, same(firstRelease));
    await expectLater(firstRelease, throwsA(same(failure)));
    await expectLater(lease.release(), throwsA(same(failure)));
    expect(lease.releaseCount, 1);
    expect(lease.isReleased, isFalse);
  });
}

final class _RecordingLease extends TemporaryFileLease {
  _RecordingLease({super.ownership = TemporaryFileOwnership.caller}) : super(path: '/tmp/IMG_0001.HEIC');

  int releaseCount = 0;

  @override
  Future<void> releaseResource() async {
    releaseCount++;
  }
}

final class _FailingLease extends TemporaryFileLease {
  _FailingLease(this.failure) : super(path: '/tmp/IMG_0001.HEIC', ownership: TemporaryFileOwnership.caller);

  final Object failure;
  int releaseCount = 0;

  @override
  Future<void> releaseResource() async {
    releaseCount++;
    throw failure;
  }
}
