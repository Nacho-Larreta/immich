import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';

final class ManualUploadAdmissionReceipts {
  static final shared = ManualUploadAdmissionReceipts();

  final Map<String, ManualUploadAttempt> _pending = {};
  final Map<String, ManualUploadAttempt> _settled = {};
  int _revision = 0;

  int get revision => _revision;

  bool begin(ManualUploadAttempt attempt) {
    if (_pending.containsKey(attempt.taskId) || _settled.containsKey(attempt.taskId)) return false;
    _pending[attempt.taskId] = attempt;
    _revision++;
    return true;
  }

  void acknowledge(ManualUploadAttempt attempt) {
    if (_pending[attempt.taskId] != attempt) return;
    _pending.remove(attempt.taskId);
    _settled[attempt.taskId] = attempt;
    _revision++;
  }

  bool isSettled(ManualUploadAttempt attempt) => _settled[attempt.taskId] == attempt;

  void acknowledgeMaterialized(ManualUploadAttempt attempt) {
    if (_settled[attempt.taskId] == attempt) return;
    if (_pending[attempt.taskId] != null && _pending[attempt.taskId] != attempt) return;
    _pending.remove(attempt.taskId);
    _settled[attempt.taskId] = attempt;
    _revision++;
  }

  void forget(ManualUploadAttempt attempt) {
    if (_pending[attempt.taskId] == attempt) {
      _pending.remove(attempt.taskId);
      _revision++;
    }
    if (_settled[attempt.taskId] == attempt) {
      _settled.remove(attempt.taskId);
      _revision++;
    }
  }
}
