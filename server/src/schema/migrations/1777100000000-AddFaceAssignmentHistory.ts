import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "face_assignment_history" (
    "id" uuid NOT NULL DEFAULT immich_uuid_v7(),
    "faceId" uuid NOT NULL,
    "ownerId" uuid NOT NULL,
    "actorId" uuid,
    "previousPersonId" uuid,
    "newPersonId" uuid,
    "source" character varying NOT NULL,
    "batchId" uuid,
    "createdAt" timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
    "revertedAt" timestamp with time zone,
    "revertedById" uuid,
    CONSTRAINT "face_assignment_history_pkey" PRIMARY KEY ("id")
  );`.execute(db);

  await sql`CREATE INDEX "face_assignment_history_ownerId_createdAt_idx" ON "face_assignment_history" ("ownerId", "createdAt");`.execute(
    db,
  );
  await sql`CREATE INDEX "face_assignment_history_faceId_createdAt_idx" ON "face_assignment_history" ("faceId", "createdAt");`.execute(
    db,
  );
  await sql`CREATE INDEX "face_assignment_history_previousPersonId_createdAt_idx" ON "face_assignment_history" ("previousPersonId", "createdAt");`.execute(
    db,
  );
  await sql`CREATE INDEX "face_assignment_history_newPersonId_createdAt_idx" ON "face_assignment_history" ("newPersonId", "createdAt");`.execute(
    db,
  );
  await sql`CREATE INDEX "face_assignment_history_batchId_createdAt_idx" ON "face_assignment_history" ("batchId", "createdAt");`.execute(
    db,
  );
  await sql`CREATE INDEX "face_assignment_history_createdAt_idx" ON "face_assignment_history" ("createdAt");`.execute(db);
  await sql`CREATE INDEX "face_assignment_history_revertedAt_idx" ON "face_assignment_history" ("revertedAt");`.execute(
    db,
  );
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP INDEX "face_assignment_history_revertedAt_idx";`.execute(db);
  await sql`DROP INDEX "face_assignment_history_createdAt_idx";`.execute(db);
  await sql`DROP INDEX "face_assignment_history_batchId_createdAt_idx";`.execute(db);
  await sql`DROP INDEX "face_assignment_history_newPersonId_createdAt_idx";`.execute(db);
  await sql`DROP INDEX "face_assignment_history_previousPersonId_createdAt_idx";`.execute(db);
  await sql`DROP INDEX "face_assignment_history_faceId_createdAt_idx";`.execute(db);
  await sql`DROP INDEX "face_assignment_history_ownerId_createdAt_idx";`.execute(db);
  await sql`DROP TABLE "face_assignment_history";`.execute(db);
}
