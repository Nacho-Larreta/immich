import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';

abstract interface class BackupRunBindingSourcePort {
  BackupRunBinding? capture();

  bool isCurrent(BackupRunBinding binding);
}
