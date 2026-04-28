import { Column, CreateDateColumn, Generated, Index, Table, Timestamp } from '@immich/sql-tools';
import { PrimaryGeneratedUuidV7Column } from 'src/decorators';
import { FaceAssignmentHistorySource } from 'src/enum';

@Table({ name: 'face_assignment_history' })
@Index({ columns: ['ownerId', 'createdAt'] })
@Index({ columns: ['faceId', 'createdAt'] })
@Index({ columns: ['previousPersonId', 'createdAt'] })
@Index({ columns: ['newPersonId', 'createdAt'] })
@Index({ columns: ['batchId', 'createdAt'] })
export class FaceAssignmentHistoryTable {
  @PrimaryGeneratedUuidV7Column()
  id!: Generated<string>;

  @Column({ type: 'uuid' })
  faceId!: string;

  @Column({ type: 'uuid' })
  ownerId!: string;

  @Column({ type: 'uuid', nullable: true })
  actorId!: string | null;

  @Column({ type: 'uuid', nullable: true })
  previousPersonId!: string | null;

  @Column({ type: 'uuid', nullable: true })
  newPersonId!: string | null;

  @Column({ type: 'character varying' })
  source!: FaceAssignmentHistorySource;

  @Column({ type: 'uuid', nullable: true })
  batchId!: string | null;

  @CreateDateColumn({ default: () => 'clock_timestamp()', index: true })
  createdAt!: Generated<Timestamp>;

  @Column({ type: 'timestamp with time zone', nullable: true, index: true })
  revertedAt!: Timestamp | null;

  @Column({ type: 'uuid', nullable: true })
  revertedById!: string | null;
}
