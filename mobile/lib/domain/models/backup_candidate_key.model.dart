import 'dart:convert';

import 'package:crypto/crypto.dart';

final class BackupCandidateKey {
  const BackupCandidateKey._(this.value);

  static const _version = 'v1';
  static final _encodedPattern = RegExp(r'^[0-9a-f]{64}$');

  final String value;

  factory BackupCandidateKey.fromLocalIdentity({required String deviceId, required String localAssetId}) {
    if (deviceId.isEmpty || localAssetId.isEmpty) throw const FormatException('Missing local candidate identity');
    final canonical = '$_version\u001f$deviceId\u001f$localAssetId';
    return BackupCandidateKey._(sha256.convert(utf8.encode(canonical)).toString());
  }

  factory BackupCandidateKey.parse(String value) {
    if (!_encodedPattern.hasMatch(value)) throw const FormatException('Invalid candidate key');
    return BackupCandidateKey._(value);
  }
}
