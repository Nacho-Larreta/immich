import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "face_suggestion_feedback" (
    "id" uuid NOT NULL DEFAULT immich_uuid_v7(),
    "ownerId" uuid NOT NULL,
    "personId" uuid NOT NULL,
    "faceId" uuid NOT NULL,
    "actorId" uuid,
    "decision" character varying NOT NULL,
    "createdAt" timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
    "updatedAt" timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT "face_suggestion_feedback_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "face_suggestion_feedback_ownerId_personId_faceId_unique" UNIQUE ("ownerId", "personId", "faceId")
  );`.execute(db);

  await sql`CREATE INDEX "face_suggestion_feedback_ownerId_personId_decision_idx" ON "face_suggestion_feedback" ("ownerId", "personId", "decision");`.execute(
    db,
  );
  await sql`CREATE INDEX "face_suggestion_feedback_faceId_idx" ON "face_suggestion_feedback" ("faceId");`.execute(db);
  await sql`CREATE INDEX "face_suggestion_feedback_updatedAt_idx" ON "face_suggestion_feedback" ("updatedAt");`.execute(
    db,
  );
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP INDEX "face_suggestion_feedback_updatedAt_idx";`.execute(db);
  await sql`DROP INDEX "face_suggestion_feedback_faceId_idx";`.execute(db);
  await sql`DROP INDEX "face_suggestion_feedback_ownerId_personId_decision_idx";`.execute(db);
  await sql`DROP TABLE "face_suggestion_feedback";`.execute(db);
}
