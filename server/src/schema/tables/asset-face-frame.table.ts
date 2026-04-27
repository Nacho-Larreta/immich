import {
  Column,
  CreateDateColumn,
  ForeignKeyColumn,
  Generated,
  PrimaryGeneratedColumn,
  Table,
  Timestamp,
  Unique,
} from '@immich/sql-tools';
import { AssetTable } from 'src/schema/tables/asset.table';

@Table({ name: 'asset_face_frame' })
@Unique({ columns: ['assetId', 'configHash', 'frameIndex'] })
export class AssetFaceFrameTable {
  @PrimaryGeneratedColumn()
  id!: Generated<string>;

  @ForeignKeyColumn(() => AssetTable, { onDelete: 'CASCADE', onUpdate: 'CASCADE' })
  assetId!: string;

  @CreateDateColumn()
  createdAt!: Generated<Timestamp>;

  @Column({ type: 'integer' })
  frameIndex!: number;

  @Column({ type: 'integer' })
  timestampMs!: number;

  @Column({ type: 'character varying' })
  path!: string;

  @Column({ type: 'integer' })
  width!: number;

  @Column({ type: 'integer' })
  height!: number;

  @Column({ type: 'character varying', length: 32 })
  configHash!: string;
}
