import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/share_sheet.interface.dart';
import 'package:immich_mobile/infrastructure/adapters/share_sheet/share_plus_sheet_adapter.dart';

final shareSheetProvider = Provider<ShareSheetPort>((_) => const SharePlusSheetAdapter());
