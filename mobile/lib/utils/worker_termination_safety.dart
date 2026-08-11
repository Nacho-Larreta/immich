import 'package:flutter/services.dart';

const unsafeWorkerTerminationCode = 'unsafe-to-terminate';
const networkDrainFailureLogCode = 'ISO-NET-DRAIN-001';
const resourceReleaseFailureCode = 'resource-release-failed';
const resourceReleaseFailureLogCode = 'ISO-RES-RELEASE-001';

bool isUnsafeWorkerTermination(Object error) => error is PlatformException && error.code == unsafeWorkerTerminationCode;

Future<void> drainNetworkBeforeRelease({
  required Future<void> Function() drainNetwork,
  required Future<void> Function() releaseResources,
  required void Function(String code) logCode,
}) async {
  try {
    await drainNetwork();
  } on Object {
    logCode(networkDrainFailureLogCode);
    throw PlatformException(code: unsafeWorkerTerminationCode, message: networkDrainFailureLogCode);
  }
  await releaseResources();
}
