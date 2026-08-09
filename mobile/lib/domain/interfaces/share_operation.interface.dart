import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/share.model.dart';

abstract interface class ShareOperation implements CancellableRequest<ShareResult> {
  Stream<ShareProgress> get progress;
}
