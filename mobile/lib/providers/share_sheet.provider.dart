import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/share_sheet.interface.dart';
import 'package:immich_mobile/infrastructure/adapters/share_sheet/share_plus_sheet_adapter.dart';
import 'package:logging/logging.dart';

final _log = Logger('ShareSheetProvider');

final shareSheetProvider = Provider<ShareSheetPort>(
  (_) => SharePlusSheetAdapter(
    reportFailure: (error) => _log.warning('Share sheet failure phase=presentation errorCode=${error.name}'),
  ),
);
