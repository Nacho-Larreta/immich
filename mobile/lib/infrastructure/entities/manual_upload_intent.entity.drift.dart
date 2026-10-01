// dart format width=80
// ignore_for_file: type=lint
import 'package:drift/drift.dart' as i0;
import 'package:immich_mobile/infrastructure/entities/manual_upload_intent.entity.drift.dart'
    as i1;
import 'package:immich_mobile/infrastructure/entities/manual_upload_intent.entity.dart'
    as i2;

typedef $$ManualUploadIntentEntityTableCreateCompanionBuilder =
    i1.ManualUploadIntentEntityCompanion Function({
      required String id,
      required String serverUrl,
      required String userId,
      required String deviceId,
      required String localAssetId,
      required int version,
      required bool active,
      required String payload,
      i0.Value<int> rowid,
    });
typedef $$ManualUploadIntentEntityTableUpdateCompanionBuilder =
    i1.ManualUploadIntentEntityCompanion Function({
      i0.Value<String> id,
      i0.Value<String> serverUrl,
      i0.Value<String> userId,
      i0.Value<String> deviceId,
      i0.Value<String> localAssetId,
      i0.Value<int> version,
      i0.Value<bool> active,
      i0.Value<String> payload,
      i0.Value<int> rowid,
    });

class $$ManualUploadIntentEntityTableFilterComposer
    extends
        i0.Composer<i0.GeneratedDatabase, i1.$ManualUploadIntentEntityTable> {
  $$ManualUploadIntentEntityTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get localAssetId => $composableBuilder(
    column: $table.localAssetId,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<bool> get active => $composableBuilder(
    column: $table.active,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => i0.ColumnFilters(column),
  );
}

class $$ManualUploadIntentEntityTableOrderingComposer
    extends
        i0.Composer<i0.GeneratedDatabase, i1.$ManualUploadIntentEntityTable> {
  $$ManualUploadIntentEntityTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get serverUrl => $composableBuilder(
    column: $table.serverUrl,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get localAssetId => $composableBuilder(
    column: $table.localAssetId,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<bool> get active => $composableBuilder(
    column: $table.active,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => i0.ColumnOrderings(column),
  );
}

class $$ManualUploadIntentEntityTableAnnotationComposer
    extends
        i0.Composer<i0.GeneratedDatabase, i1.$ManualUploadIntentEntityTable> {
  $$ManualUploadIntentEntityTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  i0.GeneratedColumn<String> get serverUrl =>
      $composableBuilder(column: $table.serverUrl, builder: (column) => column);

  i0.GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  i0.GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  i0.GeneratedColumn<String> get localAssetId => $composableBuilder(
    column: $table.localAssetId,
    builder: (column) => column,
  );

  i0.GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  i0.GeneratedColumn<bool> get active =>
      $composableBuilder(column: $table.active, builder: (column) => column);

  i0.GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);
}

class $$ManualUploadIntentEntityTableTableManager
    extends
        i0.RootTableManager<
          i0.GeneratedDatabase,
          i1.$ManualUploadIntentEntityTable,
          i1.ManualUploadIntentEntityData,
          i1.$$ManualUploadIntentEntityTableFilterComposer,
          i1.$$ManualUploadIntentEntityTableOrderingComposer,
          i1.$$ManualUploadIntentEntityTableAnnotationComposer,
          $$ManualUploadIntentEntityTableCreateCompanionBuilder,
          $$ManualUploadIntentEntityTableUpdateCompanionBuilder,
          (
            i1.ManualUploadIntentEntityData,
            i0.BaseReferences<
              i0.GeneratedDatabase,
              i1.$ManualUploadIntentEntityTable,
              i1.ManualUploadIntentEntityData
            >,
          ),
          i1.ManualUploadIntentEntityData,
          i0.PrefetchHooks Function()
        > {
  $$ManualUploadIntentEntityTableTableManager(
    i0.GeneratedDatabase db,
    i1.$ManualUploadIntentEntityTable table,
  ) : super(
        i0.TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              i1.$$ManualUploadIntentEntityTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              i1.$$ManualUploadIntentEntityTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              i1.$$ManualUploadIntentEntityTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                i0.Value<String> id = const i0.Value.absent(),
                i0.Value<String> serverUrl = const i0.Value.absent(),
                i0.Value<String> userId = const i0.Value.absent(),
                i0.Value<String> deviceId = const i0.Value.absent(),
                i0.Value<String> localAssetId = const i0.Value.absent(),
                i0.Value<int> version = const i0.Value.absent(),
                i0.Value<bool> active = const i0.Value.absent(),
                i0.Value<String> payload = const i0.Value.absent(),
                i0.Value<int> rowid = const i0.Value.absent(),
              }) => i1.ManualUploadIntentEntityCompanion(
                id: id,
                serverUrl: serverUrl,
                userId: userId,
                deviceId: deviceId,
                localAssetId: localAssetId,
                version: version,
                active: active,
                payload: payload,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String serverUrl,
                required String userId,
                required String deviceId,
                required String localAssetId,
                required int version,
                required bool active,
                required String payload,
                i0.Value<int> rowid = const i0.Value.absent(),
              }) => i1.ManualUploadIntentEntityCompanion.insert(
                id: id,
                serverUrl: serverUrl,
                userId: userId,
                deviceId: deviceId,
                localAssetId: localAssetId,
                version: version,
                active: active,
                payload: payload,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), i0.BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ManualUploadIntentEntityTableProcessedTableManager =
    i0.ProcessedTableManager<
      i0.GeneratedDatabase,
      i1.$ManualUploadIntentEntityTable,
      i1.ManualUploadIntentEntityData,
      i1.$$ManualUploadIntentEntityTableFilterComposer,
      i1.$$ManualUploadIntentEntityTableOrderingComposer,
      i1.$$ManualUploadIntentEntityTableAnnotationComposer,
      $$ManualUploadIntentEntityTableCreateCompanionBuilder,
      $$ManualUploadIntentEntityTableUpdateCompanionBuilder,
      (
        i1.ManualUploadIntentEntityData,
        i0.BaseReferences<
          i0.GeneratedDatabase,
          i1.$ManualUploadIntentEntityTable,
          i1.ManualUploadIntentEntityData
        >,
      ),
      i1.ManualUploadIntentEntityData,
      i0.PrefetchHooks Function()
    >;
i0.Index get manualUploadActiveAsset => i0.Index(
  'manual_upload_active_asset',
  'CREATE UNIQUE INDEX manual_upload_active_asset ON manual_upload_intents (server_url, user_id, device_id, local_asset_id) WHERE active = 1',
);

class $ManualUploadIntentEntityTable extends i2.ManualUploadIntentEntity
    with
        i0.TableInfo<
          $ManualUploadIntentEntityTable,
          i1.ManualUploadIntentEntityData
        > {
  @override
  final i0.GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ManualUploadIntentEntityTable(this.attachedDatabase, [this._alias]);
  static const i0.VerificationMeta _idMeta = const i0.VerificationMeta('id');
  @override
  late final i0.GeneratedColumn<String> id = i0.GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const i0.VerificationMeta _serverUrlMeta = const i0.VerificationMeta(
    'serverUrl',
  );
  @override
  late final i0.GeneratedColumn<String> serverUrl = i0.GeneratedColumn<String>(
    'server_url',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const i0.VerificationMeta _userIdMeta = const i0.VerificationMeta(
    'userId',
  );
  @override
  late final i0.GeneratedColumn<String> userId = i0.GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const i0.VerificationMeta _deviceIdMeta = const i0.VerificationMeta(
    'deviceId',
  );
  @override
  late final i0.GeneratedColumn<String> deviceId = i0.GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const i0.VerificationMeta _localAssetIdMeta =
      const i0.VerificationMeta('localAssetId');
  @override
  late final i0.GeneratedColumn<String> localAssetId =
      i0.GeneratedColumn<String>(
        'local_asset_id',
        aliasedName,
        false,
        type: i0.DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const i0.VerificationMeta _versionMeta = const i0.VerificationMeta(
    'version',
  );
  @override
  late final i0.GeneratedColumn<int> version = i0.GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: i0.DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const i0.VerificationMeta _activeMeta = const i0.VerificationMeta(
    'active',
  );
  @override
  late final i0.GeneratedColumn<bool> active = i0.GeneratedColumn<bool>(
    'active',
    aliasedName,
    false,
    type: i0.DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: i0.GeneratedColumn.constraintIsAlways(
      'CHECK ("active" IN (0, 1))',
    ),
  );
  static const i0.VerificationMeta _payloadMeta = const i0.VerificationMeta(
    'payload',
  );
  @override
  late final i0.GeneratedColumn<String> payload = i0.GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<i0.GeneratedColumn> get $columns => [
    id,
    serverUrl,
    userId,
    deviceId,
    localAssetId,
    version,
    active,
    payload,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'manual_upload_intents';
  @override
  i0.VerificationContext validateIntegrity(
    i0.Insertable<i1.ManualUploadIntentEntityData> instance, {
    bool isInserting = false,
  }) {
    final context = i0.VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('server_url')) {
      context.handle(
        _serverUrlMeta,
        serverUrl.isAcceptableOrUnknown(data['server_url']!, _serverUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_serverUrlMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('local_asset_id')) {
      context.handle(
        _localAssetIdMeta,
        localAssetId.isAcceptableOrUnknown(
          data['local_asset_id']!,
          _localAssetIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localAssetIdMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    } else if (isInserting) {
      context.missing(_versionMeta);
    }
    if (data.containsKey('active')) {
      context.handle(
        _activeMeta,
        active.isAcceptableOrUnknown(data['active']!, _activeMeta),
      );
    } else if (isInserting) {
      context.missing(_activeMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    return context;
  }

  @override
  Set<i0.GeneratedColumn> get $primaryKey => {id};
  @override
  i1.ManualUploadIntentEntityData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return i1.ManualUploadIntentEntityData(
      id: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      serverUrl: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}server_url'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      localAssetId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}local_asset_id'],
      )!,
      version: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      active: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.bool,
        data['${effectivePrefix}active'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
    );
  }

  @override
  $ManualUploadIntentEntityTable createAlias(String alias) {
    return $ManualUploadIntentEntityTable(attachedDatabase, alias);
  }
}

class ManualUploadIntentEntityData extends i0.DataClass
    implements i0.Insertable<i1.ManualUploadIntentEntityData> {
  final String id;
  final String serverUrl;
  final String userId;
  final String deviceId;
  final String localAssetId;
  final int version;
  final bool active;
  final String payload;
  const ManualUploadIntentEntityData({
    required this.id,
    required this.serverUrl,
    required this.userId,
    required this.deviceId,
    required this.localAssetId,
    required this.version,
    required this.active,
    required this.payload,
  });
  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    map['id'] = i0.Variable<String>(id);
    map['server_url'] = i0.Variable<String>(serverUrl);
    map['user_id'] = i0.Variable<String>(userId);
    map['device_id'] = i0.Variable<String>(deviceId);
    map['local_asset_id'] = i0.Variable<String>(localAssetId);
    map['version'] = i0.Variable<int>(version);
    map['active'] = i0.Variable<bool>(active);
    map['payload'] = i0.Variable<String>(payload);
    return map;
  }

  factory ManualUploadIntentEntityData.fromJson(
    Map<String, dynamic> json, {
    i0.ValueSerializer? serializer,
  }) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return ManualUploadIntentEntityData(
      id: serializer.fromJson<String>(json['id']),
      serverUrl: serializer.fromJson<String>(json['serverUrl']),
      userId: serializer.fromJson<String>(json['userId']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      localAssetId: serializer.fromJson<String>(json['localAssetId']),
      version: serializer.fromJson<int>(json['version']),
      active: serializer.fromJson<bool>(json['active']),
      payload: serializer.fromJson<String>(json['payload']),
    );
  }
  @override
  Map<String, dynamic> toJson({i0.ValueSerializer? serializer}) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'serverUrl': serializer.toJson<String>(serverUrl),
      'userId': serializer.toJson<String>(userId),
      'deviceId': serializer.toJson<String>(deviceId),
      'localAssetId': serializer.toJson<String>(localAssetId),
      'version': serializer.toJson<int>(version),
      'active': serializer.toJson<bool>(active),
      'payload': serializer.toJson<String>(payload),
    };
  }

  i1.ManualUploadIntentEntityData copyWith({
    String? id,
    String? serverUrl,
    String? userId,
    String? deviceId,
    String? localAssetId,
    int? version,
    bool? active,
    String? payload,
  }) => i1.ManualUploadIntentEntityData(
    id: id ?? this.id,
    serverUrl: serverUrl ?? this.serverUrl,
    userId: userId ?? this.userId,
    deviceId: deviceId ?? this.deviceId,
    localAssetId: localAssetId ?? this.localAssetId,
    version: version ?? this.version,
    active: active ?? this.active,
    payload: payload ?? this.payload,
  );
  ManualUploadIntentEntityData copyWithCompanion(
    i1.ManualUploadIntentEntityCompanion data,
  ) {
    return ManualUploadIntentEntityData(
      id: data.id.present ? data.id.value : this.id,
      serverUrl: data.serverUrl.present ? data.serverUrl.value : this.serverUrl,
      userId: data.userId.present ? data.userId.value : this.userId,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      localAssetId: data.localAssetId.present
          ? data.localAssetId.value
          : this.localAssetId,
      version: data.version.present ? data.version.value : this.version,
      active: data.active.present ? data.active.value : this.active,
      payload: data.payload.present ? data.payload.value : this.payload,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ManualUploadIntentEntityData(')
          ..write('id: $id, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('userId: $userId, ')
          ..write('deviceId: $deviceId, ')
          ..write('localAssetId: $localAssetId, ')
          ..write('version: $version, ')
          ..write('active: $active, ')
          ..write('payload: $payload')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    serverUrl,
    userId,
    deviceId,
    localAssetId,
    version,
    active,
    payload,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is i1.ManualUploadIntentEntityData &&
          other.id == this.id &&
          other.serverUrl == this.serverUrl &&
          other.userId == this.userId &&
          other.deviceId == this.deviceId &&
          other.localAssetId == this.localAssetId &&
          other.version == this.version &&
          other.active == this.active &&
          other.payload == this.payload);
}

class ManualUploadIntentEntityCompanion
    extends i0.UpdateCompanion<i1.ManualUploadIntentEntityData> {
  final i0.Value<String> id;
  final i0.Value<String> serverUrl;
  final i0.Value<String> userId;
  final i0.Value<String> deviceId;
  final i0.Value<String> localAssetId;
  final i0.Value<int> version;
  final i0.Value<bool> active;
  final i0.Value<String> payload;
  final i0.Value<int> rowid;
  const ManualUploadIntentEntityCompanion({
    this.id = const i0.Value.absent(),
    this.serverUrl = const i0.Value.absent(),
    this.userId = const i0.Value.absent(),
    this.deviceId = const i0.Value.absent(),
    this.localAssetId = const i0.Value.absent(),
    this.version = const i0.Value.absent(),
    this.active = const i0.Value.absent(),
    this.payload = const i0.Value.absent(),
    this.rowid = const i0.Value.absent(),
  });
  ManualUploadIntentEntityCompanion.insert({
    required String id,
    required String serverUrl,
    required String userId,
    required String deviceId,
    required String localAssetId,
    required int version,
    required bool active,
    required String payload,
    this.rowid = const i0.Value.absent(),
  }) : id = i0.Value(id),
       serverUrl = i0.Value(serverUrl),
       userId = i0.Value(userId),
       deviceId = i0.Value(deviceId),
       localAssetId = i0.Value(localAssetId),
       version = i0.Value(version),
       active = i0.Value(active),
       payload = i0.Value(payload);
  static i0.Insertable<i1.ManualUploadIntentEntityData> custom({
    i0.Expression<String>? id,
    i0.Expression<String>? serverUrl,
    i0.Expression<String>? userId,
    i0.Expression<String>? deviceId,
    i0.Expression<String>? localAssetId,
    i0.Expression<int>? version,
    i0.Expression<bool>? active,
    i0.Expression<String>? payload,
    i0.Expression<int>? rowid,
  }) {
    return i0.RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverUrl != null) 'server_url': serverUrl,
      if (userId != null) 'user_id': userId,
      if (deviceId != null) 'device_id': deviceId,
      if (localAssetId != null) 'local_asset_id': localAssetId,
      if (version != null) 'version': version,
      if (active != null) 'active': active,
      if (payload != null) 'payload': payload,
      if (rowid != null) 'rowid': rowid,
    });
  }

  i1.ManualUploadIntentEntityCompanion copyWith({
    i0.Value<String>? id,
    i0.Value<String>? serverUrl,
    i0.Value<String>? userId,
    i0.Value<String>? deviceId,
    i0.Value<String>? localAssetId,
    i0.Value<int>? version,
    i0.Value<bool>? active,
    i0.Value<String>? payload,
    i0.Value<int>? rowid,
  }) {
    return i1.ManualUploadIntentEntityCompanion(
      id: id ?? this.id,
      serverUrl: serverUrl ?? this.serverUrl,
      userId: userId ?? this.userId,
      deviceId: deviceId ?? this.deviceId,
      localAssetId: localAssetId ?? this.localAssetId,
      version: version ?? this.version,
      active: active ?? this.active,
      payload: payload ?? this.payload,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    if (id.present) {
      map['id'] = i0.Variable<String>(id.value);
    }
    if (serverUrl.present) {
      map['server_url'] = i0.Variable<String>(serverUrl.value);
    }
    if (userId.present) {
      map['user_id'] = i0.Variable<String>(userId.value);
    }
    if (deviceId.present) {
      map['device_id'] = i0.Variable<String>(deviceId.value);
    }
    if (localAssetId.present) {
      map['local_asset_id'] = i0.Variable<String>(localAssetId.value);
    }
    if (version.present) {
      map['version'] = i0.Variable<int>(version.value);
    }
    if (active.present) {
      map['active'] = i0.Variable<bool>(active.value);
    }
    if (payload.present) {
      map['payload'] = i0.Variable<String>(payload.value);
    }
    if (rowid.present) {
      map['rowid'] = i0.Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ManualUploadIntentEntityCompanion(')
          ..write('id: $id, ')
          ..write('serverUrl: $serverUrl, ')
          ..write('userId: $userId, ')
          ..write('deviceId: $deviceId, ')
          ..write('localAssetId: $localAssetId, ')
          ..write('version: $version, ')
          ..write('active: $active, ')
          ..write('payload: $payload, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

i0.Index get manualUploadActiveDestination => i0.Index(
  'manual_upload_active_destination',
  'CREATE INDEX manual_upload_active_destination ON manual_upload_intents (server_url, user_id, active, id)',
);
