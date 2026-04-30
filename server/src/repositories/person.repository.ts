import { Injectable } from '@nestjs/common';
import { ExpressionBuilder, Insertable, Kysely, Selectable, sql, Updateable } from 'kysely';
import { jsonObjectFrom } from 'kysely/helpers/postgres';
import { InjectKysely } from 'nestjs-kysely';
import { AssetFace } from 'src/database';
import { Chunked, ChunkedArray, DummyValue, GenerateSql } from 'src/decorators';
import {
  AssetFileType,
  AssetVisibility,
  FaceAssignmentHistorySource,
  FaceSuggestionFeedbackDecision,
  SourceType,
} from 'src/enum';
import { DB } from 'src/schema';
import { AssetFaceFrameTable } from 'src/schema/tables/asset-face-frame.table';
import { AssetFaceTable } from 'src/schema/tables/asset-face.table';
import { FaceAssignmentHistoryTable } from 'src/schema/tables/face-assignment-history.table';
import { FaceSearchTable } from 'src/schema/tables/face-search.table';
import { FaceSuggestionFeedbackTable } from 'src/schema/tables/face-suggestion-feedback.table';
import { PersonTable } from 'src/schema/tables/person.table';
import { dummy, removeUndefinedKeys, withFilePath } from 'src/utils/database';
import { paginationHelper, PaginationOptions } from 'src/utils/pagination';

export interface PersonSearchOptions {
  minimumFaceCount: number;
  withHidden: boolean;
  closestFaceAssetId?: string;
}

export interface PersonNameSearchOptions {
  withHidden?: boolean;
}

export interface PersonNameResponse {
  id: string;
  name: string;
}

export interface AssetFaceId {
  assetId: string;
  personId: string;
}

export interface UpdateFacesData {
  oldPersonId?: string;
  faceIds?: string[];
  newPersonId: string;
}

export interface ReassignFaceWithHistoryData {
  faceId: string;
  newPersonId: string;
  ownerId: string;
  actorId?: string;
  source: FaceAssignmentHistorySource;
  batchId?: string;
}

export interface ReassignFacesWithHistoryData extends UpdateFacesData {
  ownerId: string;
  actorId?: string;
  source: FaceAssignmentHistorySource;
  batchId?: string;
}

export interface FaceAssignmentHistoryMove {
  faceId: string;
  previousPersonId: string | null;
  newPersonId: string | null;
  history: Selectable<FaceAssignmentHistoryTable>;
}

export interface FaceSuggestionCandidate extends Selectable<AssetFaceTable> {
  distance: number;
}

export interface FaceSuggestionCandidateWithTotal extends FaceSuggestionCandidate {
  total: number;
}

export interface FaceSuggestionOptions {
  maxDistance: number;
  referenceFaceLimit: number;
}

export interface FaceSuggestionFeedbackData {
  ownerId: string;
  personId: string;
  faceId: string;
  actorId?: string;
  decision: FaceSuggestionFeedbackDecision;
}

export interface FaceForSuggestionFeedback {
  id: string;
  personId: string | null;
}

export type RevertFaceAssignmentHistoryResult =
  | { status: 'not-found' }
  | { status: 'already-reverted'; history: Selectable<FaceAssignmentHistoryTable> }
  | { status: 'conflict'; history: Selectable<FaceAssignmentHistoryTable> }
  | {
      status: 'reverted';
      history: Selectable<FaceAssignmentHistoryTable>;
      faceId: string;
      fromPersonId: string | null;
      toPersonId: string | null;
    };

export interface PersonStatistics {
  assets: number;
}

export interface DeleteFacesOptions {
  sourceType: SourceType;
}

export interface GetAllPeopleOptions {
  ownerId?: string;
  thumbnailPath?: string;
  faceAssetId?: string | null;
  isHidden?: boolean;
}

export interface GetAllFacesOptions {
  personId?: string | null;
  assetId?: string;
  sourceType?: SourceType;
}

export interface GetUnassignedFacesOptions {
  take: number;
}

export type UnassignFacesOptions = DeleteFacesOptions;

export type SelectFaceOptions = (keyof Selectable<AssetFaceTable>)[];

const withPerson = (eb: ExpressionBuilder<DB, 'asset_face'>) => {
  return jsonObjectFrom(
    eb.selectFrom('person').selectAll('person').whereRef('person.id', '=', 'asset_face.personId'),
  ).as('person');
};

const withFaceSearch = (eb: ExpressionBuilder<DB, 'asset_face'>) => {
  return jsonObjectFrom(
    eb.selectFrom('face_search').selectAll('face_search').whereRef('face_search.faceId', '=', 'asset_face.id'),
  ).as('faceSearch');
};

@Injectable()
export class PersonRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  @GenerateSql({ params: [{ oldPersonId: DummyValue.UUID, newPersonId: DummyValue.UUID }] })
  async reassignFaces({ oldPersonId, faceIds, newPersonId }: UpdateFacesData): Promise<number> {
    const result = await this.db
      .updateTable('asset_face')
      .set({ personId: newPersonId })
      .$if(!!oldPersonId, (qb) => qb.where('asset_face.personId', '=', oldPersonId!))
      .$if(!!faceIds, (qb) => qb.where('asset_face.id', 'in', faceIds!))
      .executeTakeFirst();

    return Number(result.numChangedRows ?? 0);
  }

  async reassignFaceWithHistory(data: ReassignFaceWithHistoryData): Promise<FaceAssignmentHistoryMove | null> {
    return this.db.transaction().execute(async (trx) => {
      const face = await trx
        .selectFrom('asset_face')
        .select(['asset_face.id', 'asset_face.personId'])
        .where('asset_face.id', '=', data.faceId)
        .executeTakeFirst();

      if (!face || face.personId === data.newPersonId) {
        return null;
      }

      await trx
        .updateTable('asset_face')
        .set({ personId: data.newPersonId })
        .where('asset_face.id', '=', face.id)
        .execute();

      const history = await trx
        .insertInto('face_assignment_history')
        .values({
          faceId: face.id,
          ownerId: data.ownerId,
          actorId: data.actorId ?? null,
          previousPersonId: face.personId,
          newPersonId: data.newPersonId,
          source: data.source,
          batchId: data.batchId ?? null,
          revertedAt: null,
          revertedById: null,
        })
        .returningAll()
        .executeTakeFirstOrThrow();

      return {
        faceId: face.id,
        previousPersonId: face.personId,
        newPersonId: data.newPersonId,
        history,
      };
    });
  }

  async reassignFacesWithHistory(data: ReassignFacesWithHistoryData): Promise<FaceAssignmentHistoryMove[]> {
    if (!data.oldPersonId && !data.faceIds) {
      return [];
    }

    if (data.faceIds && data.faceIds.length === 0) {
      return [];
    }

    return this.db.transaction().execute(async (trx) => {
      const faces = await trx
        .selectFrom('asset_face')
        .select(['asset_face.id', 'asset_face.personId'])
        .$if(!!data.oldPersonId, (qb) => qb.where('asset_face.personId', '=', data.oldPersonId!))
        .$if(!!data.faceIds, (qb) => qb.where('asset_face.id', 'in', data.faceIds!))
        .execute();

      const changedFaces = faces.filter((face) => face.personId !== data.newPersonId);
      if (changedFaces.length === 0) {
        return [];
      }

      const faceIds = changedFaces.map(({ id }) => id);
      await trx
        .updateTable('asset_face')
        .set({ personId: data.newPersonId })
        .where('asset_face.id', 'in', faceIds)
        .execute();

      const histories = await trx
        .insertInto('face_assignment_history')
        .values(
          changedFaces.map((face) => ({
            faceId: face.id,
            ownerId: data.ownerId,
            actorId: data.actorId ?? null,
            previousPersonId: face.personId,
            newPersonId: data.newPersonId,
            source: data.source,
            batchId: data.batchId ?? null,
            revertedAt: null,
            revertedById: null,
          })),
        )
        .returningAll()
        .execute();

      const historyByFaceId = new Map(histories.map((history) => [history.faceId, history]));
      return changedFaces.map((face) => ({
        faceId: face.id,
        previousPersonId: face.personId,
        newPersonId: data.newPersonId,
        history: historyByFaceId.get(face.id)!,
      }));
    });
  }

  async unassignFaces({ sourceType }: UnassignFacesOptions): Promise<void> {
    await this.db
      .updateTable('asset_face')
      .set({ personId: null })
      .where('asset_face.sourceType', '=', sourceType)
      .execute();
  }

  @GenerateSql({ params: [[DummyValue.UUID]] })
  @Chunked()
  async delete(ids: string[]): Promise<void> {
    if (ids.length === 0) {
      return;
    }

    await this.db.deleteFrom('person').where('person.id', 'in', ids).execute();
  }

  async deleteFaces({ sourceType }: DeleteFacesOptions): Promise<void> {
    await this.db.deleteFrom('asset_face').where('asset_face.sourceType', '=', sourceType).execute();
  }

  async deleteMachineLearningFacesAndFrames(): Promise<string[]> {
    return this.db.transaction().execute(async (trx) => {
      await trx.deleteFrom('asset_face').where('asset_face.sourceType', '=', SourceType.MachineLearning).execute();
      const frames = await trx.deleteFrom('asset_face_frame').returning('path').execute();
      return frames.map(({ path }) => path);
    });
  }

  async getFaceFramePaths(assetId: string): Promise<string[]> {
    const frames = await this.db
      .selectFrom('asset_face_frame')
      .select('path')
      .where('asset_face_frame.assetId', '=', assetId)
      .execute();

    return frames.map(({ path }) => path);
  }

  async upsertFaceFrames(frames: Insertable<AssetFaceFrameTable>[]) {
    if (frames.length === 0) {
      return [];
    }

    return this.db
      .insertInto('asset_face_frame')
      .values(frames)
      .onConflict((oc) =>
        oc.columns(['assetId', 'configHash', 'frameIndex']).doUpdateSet((eb) => ({
          timestampMs: eb.ref('excluded.timestampMs'),
          path: eb.ref('excluded.path'),
          width: eb.ref('excluded.width'),
          height: eb.ref('excluded.height'),
        })),
      )
      .returningAll()
      .execute();
  }

  getAllFaces(options: GetAllFacesOptions = {}) {
    return this.db
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .$if(options.personId === null, (qb) => qb.where('asset_face.personId', 'is', null))
      .$if(!!options.personId, (qb) => qb.where('asset_face.personId', '=', options.personId!))
      .$if(!!options.sourceType, (qb) => qb.where('asset_face.sourceType', '=', options.sourceType!))
      .$if(!!options.assetId, (qb) => qb.where('asset_face.assetId', '=', options.assetId!))
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .stream();
  }

  async getUnassignedFacesForUser(userId: string, options: GetUnassignedFacesOptions) {
    return this.db
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .innerJoin('asset', 'asset.id', 'asset_face.assetId')
      .where('asset.ownerId', '=', userId)
      .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
      .where('asset.deletedAt', 'is', null)
      .where('asset_face.personId', 'is', null)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .orderBy('asset.fileCreatedAt', 'desc')
      .orderBy('asset_face.updatedAt', 'desc')
      .limit(options.take)
      .execute();
  }

  async getUnassignedFaceCountForUser(userId: string) {
    const zero = sql<number>`0`;
    const result = await this.db
      .selectFrom('asset_face')
      .innerJoin('asset', 'asset.id', 'asset_face.assetId')
      .where('asset.ownerId', '=', userId)
      .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
      .where('asset.deletedAt', 'is', null)
      .where('asset_face.personId', 'is', null)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .select((eb) => eb.fn.coalesce(eb.fn.countAll<number>(), zero).as('count'))
      .executeTakeFirstOrThrow();

    return result.count;
  }

  getAll(options: GetAllPeopleOptions = {}) {
    return this.db
      .selectFrom('person')
      .selectAll('person')
      .$if(!!options.ownerId, (qb) => qb.where('person.ownerId', '=', options.ownerId!))
      .$if(options.thumbnailPath !== undefined, (qb) => qb.where('person.thumbnailPath', '=', options.thumbnailPath!))
      .$if(options.faceAssetId === null, (qb) => qb.where('person.faceAssetId', 'is', null))
      .$if(!!options.faceAssetId, (qb) => qb.where('person.faceAssetId', '=', options.faceAssetId!))
      .$if(options.isHidden !== undefined, (qb) => qb.where('person.isHidden', '=', options.isHidden!))
      .stream();
  }

  @GenerateSql()
  getFileSamples() {
    return this.db
      .selectFrom('person')
      .select(['id', 'thumbnailPath'])
      .where('thumbnailPath', '!=', sql.lit(''))
      .limit(sql.lit(3))
      .execute();
  }

  @GenerateSql({ params: [{ take: 1, skip: 0 }, DummyValue.UUID] })
  async getAllForUser(pagination: PaginationOptions, userId: string, options?: PersonSearchOptions) {
    const items = await this.db
      .selectFrom('person')
      .selectAll('person')
      .innerJoin('asset_face', 'asset_face.personId', 'person.id')
      .innerJoin('asset', (join) =>
        join
          .onRef('asset_face.assetId', '=', 'asset.id')
          .on('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
          .on('asset.deletedAt', 'is', null),
      )
      .where('person.ownerId', '=', userId)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .orderBy('person.isHidden', 'asc')
      .orderBy('person.isFavorite', 'desc')
      .having((eb) =>
        eb.or([
          eb('person.name', '!=', ''),
          eb((innerEb) => innerEb.fn.count('asset_face.assetId'), '>=', options?.minimumFaceCount || 1),
        ]),
      )
      .groupBy('person.id')
      .$if(!!options?.closestFaceAssetId, (qb) =>
        qb.orderBy((eb) =>
          eb(
            (eb) =>
              eb
                .selectFrom('face_search')
                .select('face_search.embedding')
                .whereRef('face_search.faceId', '=', 'person.faceAssetId'),
            '<=>',
            (eb) =>
              eb
                .selectFrom('face_search')
                .select('face_search.embedding')
                .where('face_search.faceId', '=', options!.closestFaceAssetId!),
          ),
        ),
      )
      .$if(!options?.closestFaceAssetId, (qb) =>
        qb
          .orderBy(sql`NULLIF(person.name, '') is null`, 'asc')
          .orderBy((eb) => eb.fn.count('asset_face.assetId'), 'desc')
          .orderBy(sql`NULLIF(person.name, '')`, (om) => om.asc().nullsLast())
          .orderBy('person.createdAt'),
      )
      .$if(!options?.withHidden, (qb) => qb.where('person.isHidden', '=', false))
      .offset(pagination.skip ?? 0)
      .limit(pagination.take + 1)
      .execute();

    return paginationHelper(items, pagination.take);
  }

  @GenerateSql()
  getAllWithoutFaces() {
    return this.db
      .selectFrom('person')
      .selectAll('person')
      .leftJoin('asset_face', 'asset_face.personId', 'person.id')
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .having((eb) => eb.fn.count('asset_face.assetId'), '=', 0)
      .groupBy('person.id')
      .execute();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getFaces(assetId: string, options?: { isVisible?: boolean }) {
    const isVisible = options === undefined ? true : options.isVisible;

    return this.db
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .select(withPerson)
      .where('asset_face.assetId', '=', assetId)
      .where('asset_face.deletedAt', 'is', null)
      .$if(isVisible !== undefined, (qb) => qb.where('asset_face.isVisible', '=', isVisible!))
      .orderBy('asset_face.boundingBoxX1', 'asc')
      .execute();
  }

  @GenerateSql({ params: [{ take: 1, skip: 0 }, DummyValue.UUID] })
  async getFacesForPerson(pagination: PaginationOptions, personId: string) {
    const items = await this.db
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .select(withPerson)
      .innerJoin('asset', (join) =>
        join
          .onRef('asset.id', '=', 'asset_face.assetId')
          .on('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
          .on('asset.deletedAt', 'is', null)
          .on('asset.isOffline', '=', false),
      )
      .where('asset_face.personId', '=', personId)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .orderBy('asset.fileCreatedAt', 'desc')
      .orderBy('asset_face.updatedAt', 'desc')
      .offset(pagination.skip ?? 0)
      .limit(pagination.take + 1)
      .execute();

    return paginationHelper(items, pagination.take);
  }

  async getFaceSuggestionsForPerson(
    pagination: PaginationOptions,
    ownerId: string,
    personId: string,
    options: FaceSuggestionOptions,
  ) {
    const distance = sql<number>`min(face_search.embedding <=> reference_face_embeddings.embedding)`;
    const items = await this.db
      .with('reference_face_embeddings', (qb) =>
        qb
          .selectFrom('asset_face')
          .innerJoin('asset', (join) =>
            join
              .onRef('asset.id', '=', 'asset_face.assetId')
              .on('asset.ownerId', '=', ownerId)
              .on('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
              .on('asset.deletedAt', 'is', null)
              .on('asset.isOffline', '=', false),
          )
          .innerJoin('face_search', 'face_search.faceId', 'asset_face.id')
          .select(['face_search.embedding'])
          .where('asset_face.personId', '=', personId)
          .where('asset_face.deletedAt', 'is', null)
          .where('asset_face.isVisible', 'is', true)
          .orderBy('asset_face.updatedAt', 'desc')
          .limit(options.referenceFaceLimit),
      )
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .select(distance.as('distance'))
      .select(sql<number>`(count(*) over())::int`.as('total'))
      .innerJoin('asset', (join) =>
        join
          .onRef('asset.id', '=', 'asset_face.assetId')
          .on('asset.ownerId', '=', ownerId)
          .on('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
          .on('asset.deletedAt', 'is', null)
          .on('asset.isOffline', '=', false),
      )
      .innerJoin('face_search', 'face_search.faceId', 'asset_face.id')
      .innerJoin('reference_face_embeddings', (join) => join.on(sql<boolean>`true`))
      .leftJoin('face_suggestion_feedback', (join) =>
        join
          .onRef('face_suggestion_feedback.faceId', '=', 'asset_face.id')
          .on('face_suggestion_feedback.ownerId', '=', ownerId)
          .on('face_suggestion_feedback.personId', '=', personId)
          .on('face_suggestion_feedback.decision', '=', FaceSuggestionFeedbackDecision.Rejected),
      )
      .where('asset_face.personId', 'is', null)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .where('face_suggestion_feedback.id', 'is', null)
      .groupBy('asset_face.id')
      .having(distance, '<=', options.maxDistance)
      .orderBy('distance')
      .orderBy('asset_face.updatedAt', 'desc')
      .offset(pagination.skip ?? 0)
      .limit(pagination.take + 1)
      .execute();

    return paginationHelper(items as FaceSuggestionCandidateWithTotal[], pagination.take);
  }

  async getFaceForSuggestionFeedback(ownerId: string, faceId: string): Promise<FaceForSuggestionFeedback | undefined> {
    return this.db
      .selectFrom('asset_face')
      .innerJoin('asset', (join) =>
        join
          .onRef('asset.id', '=', 'asset_face.assetId')
          .on('asset.ownerId', '=', ownerId)
          .on('asset.deletedAt', 'is', null)
          .on('asset.isOffline', '=', false),
      )
      .select(['asset_face.id', 'asset_face.personId'])
      .where('asset_face.id', '=', faceId)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .executeTakeFirst();
  }

  async upsertFaceSuggestionFeedback(
    data: FaceSuggestionFeedbackData,
  ): Promise<Selectable<FaceSuggestionFeedbackTable>> {
    return this.db
      .insertInto('face_suggestion_feedback')
      .values({
        ownerId: data.ownerId,
        personId: data.personId,
        faceId: data.faceId,
        actorId: data.actorId ?? null,
        decision: data.decision,
      })
      .onConflict((oc) =>
        oc.columns(['ownerId', 'personId', 'faceId']).doUpdateSet({
          actorId: data.actorId ?? null,
          decision: data.decision,
          updatedAt: sql`clock_timestamp()`,
        }),
      )
      .returningAll()
      .executeTakeFirstOrThrow();
  }

  async getFaceAssignmentHistoryForPerson(pagination: PaginationOptions, ownerId: string, personId: string) {
    const items = await this.db
      .selectFrom('face_assignment_history')
      .selectAll('face_assignment_history')
      .where('face_assignment_history.ownerId', '=', ownerId)
      .where((eb) =>
        eb.or([
          eb('face_assignment_history.previousPersonId', '=', personId),
          eb('face_assignment_history.newPersonId', '=', personId),
        ]),
      )
      .orderBy('face_assignment_history.createdAt', 'desc')
      .orderBy('face_assignment_history.id', 'desc')
      .offset(pagination.skip ?? 0)
      .limit(pagination.take + 1)
      .execute();

    return paginationHelper(items, pagination.take);
  }

  async revertFaceAssignmentHistory(
    id: string,
    ownerId: string,
    personId: string,
    actorId?: string,
  ): Promise<RevertFaceAssignmentHistoryResult> {
    return this.db.transaction().execute(async (trx) => {
      const history = await trx
        .selectFrom('face_assignment_history')
        .selectAll('face_assignment_history')
        .where('face_assignment_history.id', '=', id)
        .where('face_assignment_history.ownerId', '=', ownerId)
        .where((eb) =>
          eb.or([
            eb('face_assignment_history.previousPersonId', '=', personId),
            eb('face_assignment_history.newPersonId', '=', personId),
          ]),
        )
        .executeTakeFirst();

      if (!history) {
        return { status: 'not-found' };
      }

      if (history.revertedAt) {
        return { status: 'already-reverted', history };
      }

      const face = await trx
        .selectFrom('asset_face')
        .select(['asset_face.id', 'asset_face.personId'])
        .where('asset_face.id', '=', history.faceId)
        .where('asset_face.deletedAt', 'is', null)
        .executeTakeFirst();

      if (!face || face.personId !== history.newPersonId) {
        return { status: 'conflict', history };
      }

      await trx
        .updateTable('asset_face')
        .set({ personId: history.previousPersonId })
        .where('asset_face.id', '=', history.faceId)
        .execute();

      const revertedHistory = await trx
        .updateTable('face_assignment_history')
        .set({ revertedAt: new Date(), revertedById: actorId ?? null })
        .where('face_assignment_history.id', '=', history.id)
        .returningAll()
        .executeTakeFirstOrThrow();

      return {
        status: 'reverted',
        history: revertedHistory,
        faceId: history.faceId,
        fromPersonId: history.newPersonId,
        toPersonId: history.previousPersonId,
      };
    });
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getFaceById(id: string) {
    // TODO return null instead of find or fail
    return this.db
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .select(withPerson)
      .where('asset_face.id', '=', id)
      .where('asset_face.deletedAt', 'is', null)
      .executeTakeFirstOrThrow();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getFaceSourceImage(id: string) {
    return this.db
      .selectFrom('asset_face')
      .innerJoin('asset', 'asset_face.assetId', 'asset.id')
      .leftJoin('asset_face_frame', 'asset_face.frameId', 'asset_face_frame.id')
      .select(['asset_face.id', 'asset.type', 'asset.originalPath', 'asset_face_frame.path as faceFramePath'])
      .select((eb) => withFilePath(eb, AssetFileType.Preview).as('previewPath'))
      .where('asset_face.id', '=', id)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset.deletedAt', 'is', null)
      .executeTakeFirst();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getFaceForFacialRecognitionJob(id: string) {
    return this.db
      .selectFrom('asset_face')
      .select(['asset_face.id', 'asset_face.personId', 'asset_face.sourceType'])
      .select((eb) =>
        jsonObjectFrom(
          eb
            .selectFrom('asset')
            .select(['asset.ownerId', 'asset.visibility', 'asset.fileCreatedAt'])
            .whereRef('asset.id', '=', 'asset_face.assetId'),
        ).as('asset'),
      )
      .select(withFaceSearch)
      .where('asset_face.id', '=', id)
      .where('asset_face.deletedAt', 'is', null)
      .executeTakeFirst();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getDataForThumbnailGenerationJob(id: string) {
    return this.db
      .selectFrom('person')
      .innerJoin('asset_face', 'asset_face.id', 'person.faceAssetId')
      .innerJoin('asset', 'asset_face.assetId', 'asset.id')
      .leftJoin('asset_exif', 'asset_exif.assetId', 'asset.id')
      .leftJoin('asset_face_frame', 'asset_face.frameId', 'asset_face_frame.id')
      .select([
        'person.ownerId',
        'asset_face.boundingBoxX1 as x1',
        'asset_face.boundingBoxY1 as y1',
        'asset_face.boundingBoxX2 as x2',
        'asset_face.boundingBoxY2 as y2',
        'asset_face.imageWidth as oldWidth',
        'asset_face.imageHeight as oldHeight',
        'asset.type',
        'asset.originalPath',
        'asset_exif.orientation as exifOrientation',
        'asset_face_frame.path as faceFramePath',
      ])
      .select((eb) => withFilePath(eb, AssetFileType.Preview).as('previewPath'))
      .where('person.id', '=', id)
      .where('asset_face.deletedAt', 'is', null)
      .executeTakeFirst();
  }

  @GenerateSql({ params: [DummyValue.UUID, DummyValue.UUID] })
  async reassignFace(assetFaceId: string, newPersonId: string): Promise<number> {
    const result = await this.db
      .updateTable('asset_face')
      .set({ personId: newPersonId })
      .where('asset_face.id', '=', assetFaceId)
      .executeTakeFirst();

    return Number(result.numChangedRows ?? 0);
  }

  getById(personId: string) {
    return this.db //
      .selectFrom('person')
      .selectAll('person')
      .where('person.id', '=', personId)
      .executeTakeFirst();
  }

  @GenerateSql({ params: [DummyValue.UUID, DummyValue.STRING, { withHidden: true }] })
  getByName(userId: string, personName: string, { withHidden }: PersonNameSearchOptions) {
    return this.db
      .with('similarity_threshold', (db) =>
        db.selectNoFrom(sql`set_config('pg_trgm.word_similarity_threshold', '0.5', true)`.as('thresh')),
      )
      .selectFrom(['similarity_threshold', 'person'])
      .selectAll('person')
      .where('person.ownerId', '=', userId)
      .where(() => sql`f_unaccent("person"."name") %> f_unaccent(${personName})`)
      .orderBy(sql`f_unaccent("person"."name") <->>> f_unaccent(${personName})`)
      .limit(100)
      .$if(!withHidden, (qb) => qb.where('person.isHidden', '=', false))
      .execute();
  }

  @GenerateSql({ params: [DummyValue.UUID, { withHidden: true }] })
  getDistinctNames(userId: string, { withHidden }: PersonNameSearchOptions): Promise<PersonNameResponse[]> {
    return this.db
      .selectFrom('person')
      .select(['person.id', 'person.name'])
      .distinctOn((eb) => eb.fn('lower', ['person.name']))
      .where((eb) => eb.and([eb('person.ownerId', '=', userId), eb('person.name', '!=', '')]))
      .$if(!withHidden, (qb) => qb.where('person.isHidden', '=', false))
      .execute();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  async getStatistics(personId: string): Promise<PersonStatistics> {
    const result = await this.db
      .selectFrom('asset_face')
      .leftJoin('asset', (join) =>
        join
          .onRef('asset.id', '=', 'asset_face.assetId')
          .on('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
          .on('asset.deletedAt', 'is', null),
      )
      .select((eb) => eb.fn.count(eb.fn('distinct', ['asset.id'])).as('count'))
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .where('asset_face.personId', '=', personId)
      .executeTakeFirst();

    return {
      assets: result ? Number(result.count) : 0,
    };
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getNumberOfPeople(userId: string) {
    const zero = sql.lit(0);
    return this.db
      .selectFrom('person')
      .where((eb) =>
        eb.exists((eb) =>
          eb
            .selectFrom('asset_face')
            .whereRef('asset_face.personId', '=', 'person.id')
            .where('asset_face.deletedAt', 'is', null)
            .where('asset_face.isVisible', '=', true)
            .where((eb) =>
              eb.exists((eb) =>
                eb
                  .selectFrom('asset')
                  .whereRef('asset.id', '=', 'asset_face.assetId')
                  .where('asset.visibility', '=', sql.lit(AssetVisibility.Timeline))
                  .where('asset.deletedAt', 'is', null),
              ),
            ),
        ),
      )
      .where('person.ownerId', '=', userId)
      .select((eb) => eb.fn.coalesce(eb.fn.countAll<number>(), zero).as('total'))
      .select((eb) => eb.fn.coalesce(eb.fn.countAll<number>().filterWhere('isHidden', '=', true), zero).as('hidden'))
      .executeTakeFirstOrThrow();
  }

  create(person: Insertable<PersonTable>) {
    return this.db.insertInto('person').values(person).returningAll().executeTakeFirstOrThrow();
  }

  async createAll(people: Insertable<PersonTable>[]): Promise<string[]> {
    if (people.length === 0) {
      return [];
    }

    const results = await this.db.insertInto('person').values(people).returningAll().execute();
    return results.map(({ id }) => id);
  }

  @GenerateSql({ params: [[], [], [{ faceId: DummyValue.UUID, embedding: DummyValue.VECTOR }]] })
  async refreshFaces(
    facesToAdd: (Insertable<AssetFaceTable> & { assetId: string })[],
    faceIdsToRemove: string[],
    embeddingsToAdd?: Insertable<FaceSearchTable>[],
  ): Promise<void> {
    let query = this.db;
    if (facesToAdd.length > 0) {
      (query as any) = query.with('added', (db) => db.insertInto('asset_face').values(facesToAdd));
    }

    if (faceIdsToRemove.length > 0) {
      (query as any) = query.with('removed', (db) =>
        db.deleteFrom('asset_face').where('asset_face.id', '=', (eb) => eb.fn.any(eb.val(faceIdsToRemove))),
      );
    }

    if (embeddingsToAdd?.length) {
      (query as any) = query.with('added_embeddings', (db) => db.insertInto('face_search').values(embeddingsToAdd));
    }

    await query.selectFrom(dummy).execute();
  }

  async update(person: Updateable<PersonTable> & { id: string }) {
    return this.db
      .updateTable('person')
      .set(person)
      .where('person.id', '=', person.id)
      .returningAll()
      .executeTakeFirstOrThrow();
  }

  async updateAll(people: Insertable<PersonTable>[]): Promise<void> {
    if (people.length === 0) {
      return;
    }

    await this.db
      .insertInto('person')
      .values(people)
      .onConflict((oc) =>
        oc.column('id').doUpdateSet((eb) =>
          removeUndefinedKeys(
            {
              name: eb.ref('excluded.name'),
              birthDate: eb.ref('excluded.birthDate'),
              thumbnailPath: eb.ref('excluded.thumbnailPath'),
              faceAssetId: eb.ref('excluded.faceAssetId'),
              isHidden: eb.ref('excluded.isHidden'),
              isFavorite: eb.ref('excluded.isFavorite'),
              color: eb.ref('excluded.color'),
            },
            people[0],
          ),
        ),
      )
      .execute();
  }

  @GenerateSql({ params: [[{ assetId: DummyValue.UUID, personId: DummyValue.UUID }]] })
  @ChunkedArray()
  getFacesByIds(ids: AssetFaceId[]) {
    if (ids.length === 0) {
      return Promise.resolve([]);
    }

    const assetIds: string[] = [];
    const personIds: string[] = [];
    for (const { assetId, personId } of ids) {
      assetIds.push(assetId);
      personIds.push(personId);
    }

    return this.db
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .select(withPerson)
      .where('asset_face.assetId', 'in', assetIds)
      .where('asset_face.personId', 'in', personIds)
      .where('asset_face.deletedAt', 'is', null)
      .execute();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getRandomFace(personId: string) {
    return this.db
      .selectFrom('asset_face')
      .selectAll('asset_face')
      .where('asset_face.personId', '=', personId)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .executeTakeFirst();
  }

  @GenerateSql()
  async getLatestFaceDate(): Promise<string | undefined> {
    const result = (await this.db
      .selectFrom('asset_job_status')
      .select((eb) => sql`${eb.fn.max('asset_job_status.facesRecognizedAt')}::text`.as('latestDate'))
      .executeTakeFirst()) as { latestDate: string } | undefined;

    return result?.latestDate;
  }

  async createAssetFace(face: Insertable<AssetFaceTable>): Promise<void> {
    await this.db.insertInto('asset_face').values(face).execute();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  async deleteAssetFace(id: string): Promise<void> {
    await this.db.deleteFrom('asset_face').where('asset_face.id', '=', id).execute();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  async softDeleteAssetFaces(id: string): Promise<void> {
    await this.db.updateTable('asset_face').set({ deletedAt: new Date() }).where('asset_face.id', '=', id).execute();
  }

  async vacuum({ reindexVectors }: { reindexVectors: boolean }): Promise<void> {
    await sql`VACUUM ANALYZE asset_face, face_search, person`.execute(this.db);
    await sql`REINDEX TABLE asset_face`.execute(this.db);
    await sql`REINDEX TABLE person`.execute(this.db);
    if (reindexVectors) {
      await sql`REINDEX TABLE face_search`.execute(this.db);
    }
  }

  @GenerateSql({ params: [[DummyValue.UUID]] })
  @Chunked()
  getForPeopleDelete(ids: string[]) {
    if (ids.length === 0) {
      return Promise.resolve([]);
    }
    return this.db.selectFrom('person').select(['id', 'thumbnailPath']).where('id', 'in', ids).execute();
  }

  @GenerateSql({ params: [[], []] })
  async updateVisibility(visible: AssetFace[], hidden: AssetFace[]): Promise<void> {
    if (visible.length === 0 && hidden.length === 0) {
      return;
    }

    await this.db.transaction().execute(async (trx) => {
      if (visible.length > 0) {
        await trx
          .updateTable('asset_face')
          .set({ isVisible: true })
          .where(
            'asset_face.id',
            'in',
            visible.map(({ id }) => id),
          )
          .execute();
      }

      if (hidden.length > 0) {
        await trx
          .updateTable('asset_face')
          .set({ isVisible: false })
          .where(
            'asset_face.id',
            'in',
            hidden.map(({ id }) => id),
          )
          .execute();
      }
    });
  }

  @GenerateSql({ params: [{ personId: DummyValue.UUID, assetId: DummyValue.UUID }] })
  getForFeatureFaceUpdate({ personId, assetId }: { personId: string; assetId: string }) {
    return this.db
      .selectFrom('asset_face')
      .select('asset_face.id')
      .where('asset_face.assetId', '=', assetId)
      .where('asset_face.personId', '=', personId)
      .innerJoin('asset', (join) => join.onRef('asset.id', '=', 'asset_face.assetId').on('asset.isOffline', '=', false))
      .executeTakeFirst();
  }

  @GenerateSql({ params: [{ personId: DummyValue.UUID, faceId: DummyValue.UUID }] })
  getForFeatureFaceUpdateByFaceId({ personId, faceId }: { personId: string; faceId: string }) {
    return this.db
      .selectFrom('asset_face')
      .select('asset_face.id')
      .where('asset_face.id', '=', faceId)
      .where('asset_face.personId', '=', personId)
      .where('asset_face.deletedAt', 'is', null)
      .where('asset_face.isVisible', 'is', true)
      .innerJoin('asset', (join) => join.onRef('asset.id', '=', 'asset_face.assetId').on('asset.isOffline', '=', false))
      .executeTakeFirst();
  }
}
