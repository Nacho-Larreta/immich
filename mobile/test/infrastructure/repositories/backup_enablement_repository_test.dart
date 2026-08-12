import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup_enablement.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_enablement.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

void main() {
  late Directory directory;
  late Drift firstDb;
  late Drift secondDb;
  late DriftBackupEnablementRepository first;
  late DriftBackupEnablementRepository second;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('immich-backup-enablement-');
    final file = File('${directory.path}/shared.sqlite');
    firstDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    await firstDb.customSelect('SELECT 1').get();
    secondDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    await secondDb.customSelect('SELECT 1').get();
    await firstDb.customStatement('PRAGMA busy_timeout = 5000');
    await secondDb.customStatement('PRAGMA busy_timeout = 5000');
    first = DriftBackupEnablementRepository(firstDb);
    second = DriftBackupEnablementRepository(secondDb);
  });

  tearDown(() async {
    await secondDb.close();
    await firstDb.close();
    await directory.delete(recursive: true);
  });

  test('stale drained generation cannot enable after another connection begins disabling', () async {
    final disabling = await first.beginDisable();
    expect(await first.completeDrain(disabling), isTrue);
    final drained = await first.read();
    expect(drained?.phase, DurableBackupEnablementPhase.disabledDrained);

    final newerDisabling = await second.beginDisable();
    expect(newerDisabling.generation, greaterThan(drained!.generation));
    expect(await first.enableFromDrained(drained), isFalse);

    expect(await _readEnabled(secondDb), isFalse);
    expect((await second.read())?.phase, DurableBackupEnablementPhase.disabling);
  });

  test('enable racing disable across connections cannot leave persisted backup enabled', () async {
    final firstDisabling = await first.beginDisable();
    expect(await first.completeDrain(firstDisabling), isTrue);
    final drained = (await first.read())!;

    final results = await Future.wait<Object>([first.enableFromDrained(drained), second.beginDisable()]);
    expect(results, hasLength(2));
    expect(await _readEnabled(firstDb), isFalse);
    expect((await first.read())?.phase, DurableBackupEnablementPhase.disabling);
  });

  test('drain failure generation cannot be enabled', () async {
    final disabling = await first.beginDisable();
    expect(await first.failDrain(disabling), isTrue);
    final failed = (await first.read())!;

    expect(failed.phase, DurableBackupEnablementPhase.drainFailed);
    expect(await second.enableFromDrained(failed), isFalse);
    expect(await _readEnabled(firstDb), isFalse);
  });
}

Future<bool> _readEnabled(Drift db) async {
  final row = await db
      .customSelect(
        'SELECT int_value FROM store_entity WHERE id = ?1',
        variables: [Variable.withInt(StoreKey.enableBackup.id)],
      )
      .getSingleOrNull();
  return row?.read<int?>('int_value') == 1;
}
