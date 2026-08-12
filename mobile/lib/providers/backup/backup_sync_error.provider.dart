import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/backup_sync.model.dart';

final backupSyncErrorProvider = StateProvider<BackupError>((_) => BackupError.none);
