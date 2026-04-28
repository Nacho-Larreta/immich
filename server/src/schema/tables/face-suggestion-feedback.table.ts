import {
  Column,
  CreateDateColumn,
  Generated,
  Index,
  Table,
  Timestamp,
  Unique,
  UpdateDateColumn,
} from '@immich/sql-tools';
import { PrimaryGeneratedUuidV7Column } from 'src/decorators';
import { FaceSuggestionFeedbackDecision } from 'src/enum';

@Table({ name: 'face_suggestion_feedback' })
@Unique({
  name: 'face_suggestion_feedback_ownerId_personId_faceId_unique',
  columns: ['ownerId', 'personId', 'faceId'],
})
@Index({ columns: ['ownerId', 'personId', 'decision'] })
@Index({ columns: ['faceId'] })
@Index({ columns: ['updatedAt'] })
export class FaceSuggestionFeedbackTable {
  @PrimaryGeneratedUuidV7Column()
  id!: Generated<string>;

  @Column({ type: 'uuid' })
  ownerId!: string;

  @Column({ type: 'uuid' })
  personId!: string;

  @Column({ type: 'uuid' })
  faceId!: string;

  @Column({ type: 'uuid', nullable: true })
  actorId!: string | null;

  @Column({ type: 'character varying' })
  decision!: FaceSuggestionFeedbackDecision;

  @CreateDateColumn({ default: () => 'clock_timestamp()' })
  createdAt!: Generated<Timestamp>;

  @UpdateDateColumn({ default: () => 'clock_timestamp()' })
  updatedAt!: Generated<Timestamp>;
}
