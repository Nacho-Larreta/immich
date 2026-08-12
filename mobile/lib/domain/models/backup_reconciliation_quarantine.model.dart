import 'dart:convert';

import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_candidate_key.model.dart';

enum BackupReconciliationQuarantineCode { definitivelyStale, completedTaskMissing, immutableMetadataMissing }

final class BackupReconciliationQuarantineEntry {
  const BackupReconciliationQuarantineEntry({
    required this.claim,
    required this.candidateKey,
    required this.bindingDigest,
    required this.code,
  });

  final BackupTaskClaim claim;
  final String candidateKey;
  final String bindingDigest;
  final BackupReconciliationQuarantineCode code;

  String get durableKey => '${claim.durableKey}:$candidateKey:$bindingDigest';

  Map<String, Object> toJsonValue() => {
    'claim': claim.toJsonValue(),
    'candidateKey': candidateKey,
    'bindingDigest': bindingDigest,
    'code': code.name,
  };

  static BackupReconciliationQuarantineEntry fromJsonValue(Object? source) {
    final value = source as Map<String, dynamic>;
    final bindingDigest = value['bindingDigest'] as String;
    final candidateKey = BackupCandidateKey.parse(value['candidateKey'] as String).value;
    if (bindingDigest.isEmpty) throw const FormatException('Empty quarantine digest');
    return BackupReconciliationQuarantineEntry(
      claim: BackupTaskClaim.fromJsonValue(value['claim']),
      candidateKey: candidateKey,
      bindingDigest: bindingDigest,
      code: BackupReconciliationQuarantineCode.values.byName(value['code'] as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackupReconciliationQuarantineEntry &&
      other.claim == claim &&
      other.candidateKey == candidateKey &&
      other.bindingDigest == bindingDigest &&
      other.code == code;

  @override
  int get hashCode => Object.hash(claim, candidateKey, bindingDigest, code);
}

final class BackupReconciliationQuarantine {
  static const schemaVersion = 2;

  BackupReconciliationQuarantine(Iterable<BackupReconciliationQuarantineEntry> entries)
    : entries = Set.unmodifiable(entries);

  final Set<BackupReconciliationQuarantineEntry> entries;

  BackupReconciliationQuarantine add(BackupReconciliationQuarantineEntry entry) =>
      BackupReconciliationQuarantine({...entries.where((current) => current.durableKey != entry.durableKey), entry});

  String toJson() {
    final ordered = entries.toList()..sort((left, right) => left.durableKey.compareTo(right.durableKey));
    return jsonEncode({
      'schemaVersion': schemaVersion,
      'entries': ordered.map((entry) => entry.toJsonValue()).toList(growable: false),
    });
  }

  static BackupReconciliationQuarantine? tryParse(String? source) {
    if (source == null || source.isEmpty) return BackupReconciliationQuarantine(const []);
    try {
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> || value['schemaVersion'] != schemaVersion) {
        return null;
      }
      return BackupReconciliationQuarantine(
        (value['entries'] as List<dynamic>).map(BackupReconciliationQuarantineEntry.fromJsonValue),
      );
    } on Object {
      return null;
    }
  }
}
