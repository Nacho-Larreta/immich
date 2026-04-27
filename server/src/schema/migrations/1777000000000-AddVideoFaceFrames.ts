import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "asset_face_frame" (
    "id" uuid NOT NULL DEFAULT uuid_generate_v4(),
    "assetId" uuid NOT NULL,
    "createdAt" timestamp with time zone NOT NULL DEFAULT now(),
    "frameIndex" integer NOT NULL,
    "timestampMs" integer NOT NULL,
    "path" character varying NOT NULL,
    "width" integer NOT NULL,
    "height" integer NOT NULL,
    "configHash" character varying(32) NOT NULL,
    CONSTRAINT "asset_face_frame_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "asset_face_frame_assetId_configHash_frameIndex_uq" UNIQUE ("assetId", "configHash", "frameIndex"),
    CONSTRAINT "asset_face_frame_assetId_fkey" FOREIGN KEY ("assetId") REFERENCES "asset" ("id") ON UPDATE CASCADE ON DELETE CASCADE
  );`.execute(db);

  await sql`CREATE INDEX "asset_face_frame_assetId_idx" ON "asset_face_frame" ("assetId");`.execute(db);
  await sql`ALTER TABLE "asset_face" ADD COLUMN "frameId" uuid;`.execute(db);
  await sql`ALTER TABLE "asset_face" ADD CONSTRAINT "asset_face_frameId_fkey" FOREIGN KEY ("frameId") REFERENCES "asset_face_frame" ("id") ON UPDATE CASCADE ON DELETE SET NULL;`.execute(
    db,
  );
  await sql`CREATE INDEX "asset_face_frameId_idx" ON "asset_face" ("frameId");`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP INDEX "asset_face_frameId_idx";`.execute(db);
  await sql`ALTER TABLE "asset_face" DROP CONSTRAINT "asset_face_frameId_fkey";`.execute(db);
  await sql`ALTER TABLE "asset_face" DROP COLUMN "frameId";`.execute(db);
  await sql`DROP INDEX "asset_face_frame_assetId_idx";`.execute(db);
  await sql`DROP TABLE "asset_face_frame";`.execute(db);
}
