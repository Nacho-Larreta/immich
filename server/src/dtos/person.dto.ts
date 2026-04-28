import { Selectable } from 'kysely';
import { createZodDto } from 'nestjs-zod';
import { AssetFace, Person } from 'src/database';
import { HistoryBuilder } from 'src/decorators';
import { AuthDto } from 'src/dtos/auth.dto';
import { AssetEditActionItem } from 'src/dtos/editing.dto';
import { FaceAssignmentHistorySourceSchema, FaceSuggestionFeedbackDecisionSchema, SourceTypeSchema } from 'src/enum';
import { AssetFaceTable } from 'src/schema/tables/asset-face.table';
import { FaceAssignmentHistoryTable } from 'src/schema/tables/face-assignment-history.table';
import { FaceSuggestionFeedbackTable } from 'src/schema/tables/face-suggestion-feedback.table';
import { ImageDimensions, MaybeDehydrated } from 'src/types';
import { asBirthDateString, asDateString } from 'src/utils/date';
import { transformFaceBoundingBox } from 'src/utils/transform';
import { emptyStringToNull, hexColor, stringToBool } from 'src/validation';
import z from 'zod';

const PersonCreateSchema = z
  .object({
    name: z.string().optional().describe('Person name'),
    // Note: the mobile app cannot currently set the birth date to null.
    birthDate: emptyStringToNull(z.string().meta({ format: 'date' }).nullable())
      .optional()
      .refine((val) => (val ? new Date(val) <= new Date() : true), { error: 'Birth date cannot be in the future' })
      .describe('Person date of birth'),
    isHidden: z.boolean().optional().describe('Person visibility (hidden)'),
    isFavorite: z.boolean().optional().describe('Mark as favorite'),
    color: emptyStringToNull(hexColor.nullable()).optional().describe('Person color (hex)'),
  })
  .meta({ id: 'PersonCreateDto' });

const PersonUpdateSchema = PersonCreateSchema.extend({
  featureFaceAssetId: z.uuidv4().optional().describe('Asset ID used for feature face thumbnail'),
  featureFaceId: z.uuidv4().optional().describe('Asset face ID used for feature face thumbnail'),
}).meta({ id: 'PersonUpdateDto' });

const PeopleUpdateItemSchema = PersonUpdateSchema.extend({
  id: z.string().describe('Person ID'),
}).meta({ id: 'PeopleUpdateItem' });

const PeopleUpdateSchema = z
  .object({
    people: z.array(PeopleUpdateItemSchema).describe('People to update'),
  })
  .meta({ id: 'PeopleUpdateDto' });

const MergePersonSchema = z
  .object({
    ids: z.array(z.uuidv4()).describe('Person IDs to merge'),
  })
  .meta({ id: 'MergePersonDto' });

const PersonSearchSchema = z
  .object({
    withHidden: stringToBool.optional().describe('Include hidden people'),
    closestPersonId: z.uuidv4().optional().describe('Closest person ID for similarity search'),
    closestAssetId: z.uuidv4().optional().describe('Closest asset ID for similarity search'),
    page: z.coerce.number().min(1).default(1).describe('Page number for pagination'),
    size: z.coerce.number().min(1).max(1000).default(500).describe('Number of items per page'),
  })
  .meta({ id: 'PersonSearchDto' });

const PersonResponseSchema = z
  .object({
    id: z.string().describe('Person ID'),
    name: z.string().describe('Person name'),
    // TODO: use `isoDateToDate` when using `ZodSerializerDto` on the controllers.
    birthDate: z.string().meta({ format: 'date' }).describe('Person date of birth').nullable(),
    thumbnailPath: z.string().describe('Thumbnail path'),
    isHidden: z.boolean().describe('Is hidden'),
    // TODO: use `isoDatetimeToDate` when using `ZodSerializerDto` on the controllers.
    updatedAt: z
      .string()
      .meta({ format: 'date-time' })
      .optional()
      .describe('Last update date')
      .meta(new HistoryBuilder().added('v1.107.0').stable('v2').getExtensions()),
    isFavorite: z
      .boolean()
      .optional()
      .describe('Is favorite')
      .meta(new HistoryBuilder().added('v1.126.0').stable('v2').getExtensions()),
    color: z
      .string()
      .optional()
      .describe('Person color (hex)')
      .meta(new HistoryBuilder().added('v1.126.0').stable('v2').getExtensions()),
  })
  .meta({ id: 'PersonResponseDto' });

export class PersonCreateDto extends createZodDto(PersonCreateSchema) {}
export class PersonUpdateDto extends createZodDto(PersonUpdateSchema) {}
export class PeopleUpdateDto extends createZodDto(PeopleUpdateSchema) {}
export class MergePersonDto extends createZodDto(MergePersonSchema) {}
export class PersonSearchDto extends createZodDto(PersonSearchSchema) {}
export class PersonResponseDto extends createZodDto(PersonResponseSchema) {}

const PersonFacesSearchSchema = z
  .object({
    page: z.coerce.number().min(1).default(1).describe('Page number for pagination'),
    size: z.coerce.number().min(1).max(500).default(100).describe('Number of face references per page'),
  })
  .meta({ id: 'PersonFacesSearchDto' });

export class PersonFacesSearchDto extends createZodDto(PersonFacesSearchSchema) {}

export const AssetFaceWithoutPersonResponseSchema = z
  .object({
    id: z.uuidv4().describe('Face ID'),
    assetId: z.uuidv4().describe('Asset ID'),
    imageHeight: z.int().min(0).describe('Image height in pixels'),
    imageWidth: z.int().min(0).describe('Image width in pixels'),
    boundingBoxX1: z.int().describe('Bounding box X1 coordinate'),
    boundingBoxX2: z.int().describe('Bounding box X2 coordinate'),
    boundingBoxY1: z.int().describe('Bounding box Y1 coordinate'),
    boundingBoxY2: z.int().describe('Bounding box Y2 coordinate'),
    sourceType: SourceTypeSchema.optional(),
  })
  .describe('Asset face without person')
  .meta({ id: 'AssetFaceWithoutPersonResponseDto' });

class AssetFaceWithoutPersonResponseDto extends createZodDto(AssetFaceWithoutPersonResponseSchema) {}

export const PersonWithFacesResponseSchema = PersonResponseSchema.extend({
  faces: z.array(AssetFaceWithoutPersonResponseSchema),
}).meta({ id: 'PersonWithFacesResponseDto' });

export class PersonWithFacesResponseDto extends createZodDto(PersonWithFacesResponseSchema) {}

const AssetFaceResponseSchema = AssetFaceWithoutPersonResponseSchema.extend({
  person: PersonResponseSchema.nullable(),
}).meta({ id: 'AssetFaceResponseDto' });

export class AssetFaceResponseDto extends createZodDto(AssetFaceResponseSchema) {}

const PersonFacesResponseSchema = z
  .object({
    faces: z.array(AssetFaceResponseSchema).describe('Face references assigned to the person'),
    hasNextPage: z.boolean().describe('Whether there are more face references'),
  })
  .meta({ id: 'PersonFacesResponseDto' });

export class PersonFacesResponseDto extends createZodDto(PersonFacesResponseSchema) {}

const PersonFaceAssignmentHistorySearchSchema = z
  .object({
    page: z.coerce.number().min(1).default(1).describe('Page number for pagination'),
    size: z.coerce.number().min(1).max(100).default(20).describe('Number of history entries per page'),
  })
  .meta({ id: 'PersonFaceAssignmentHistorySearchDto' });

export class PersonFaceAssignmentHistorySearchDto extends createZodDto(PersonFaceAssignmentHistorySearchSchema) {}

const PersonFaceAssignmentHistoryParamSchema = z
  .object({
    id: z.uuidv4().describe('Person ID'),
    historyId: z.uuidv4().describe('Face assignment history ID'),
  })
  .meta({ id: 'PersonFaceAssignmentHistoryParamDto' });

export class PersonFaceAssignmentHistoryParamDto extends createZodDto(PersonFaceAssignmentHistoryParamSchema) {}

const PersonFaceAssignmentHistoryResponseSchema = z
  .object({
    id: z.uuidv4().describe('Face assignment history ID'),
    faceId: z.uuidv4().describe('Face ID'),
    previousPersonId: z.uuidv4().nullable().describe('Person ID before the change'),
    newPersonId: z.uuidv4().nullable().describe('Person ID after the change'),
    source: FaceAssignmentHistorySourceSchema,
    batchId: z.uuidv4().nullable().describe('Shared ID for related history entries'),
    createdAt: z.string().meta({ format: 'date-time' }).describe('Change timestamp'),
    revertedAt: z.string().meta({ format: 'date-time' }).nullable().describe('Revert timestamp'),
  })
  .meta({ id: 'PersonFaceAssignmentHistoryResponseDto' });

export class PersonFaceAssignmentHistoryResponseDto extends createZodDto(PersonFaceAssignmentHistoryResponseSchema) {}

const PersonFaceAssignmentHistoryPageResponseSchema = z
  .object({
    history: z.array(PersonFaceAssignmentHistoryResponseSchema).describe('Face assignment history entries'),
    hasNextPage: z.boolean().describe('Whether there are more history entries'),
  })
  .meta({ id: 'PersonFaceAssignmentHistoryPageResponseDto' });

export class PersonFaceAssignmentHistoryPageResponseDto extends createZodDto(
  PersonFaceAssignmentHistoryPageResponseSchema,
) {}

const PersonFaceSuggestionSearchSchema = z
  .object({
    page: z.coerce.number().min(1).default(1).describe('Page number for pagination'),
    size: z.coerce.number().min(1).max(50).default(10).describe('Number of suggestions per page'),
    maxDistance: z.coerce
      .number()
      .min(0)
      .max(2)
      .optional()
      .describe('Override face embedding max distance for suggestions'),
  })
  .meta({ id: 'PersonFaceSuggestionSearchDto' });

export class PersonFaceSuggestionSearchDto extends createZodDto(PersonFaceSuggestionSearchSchema) {}

const PersonFaceSuggestionResponseSchema = AssetFaceWithoutPersonResponseSchema.extend({
  distance: z.number().describe('Embedding distance from the closest reference face'),
}).meta({ id: 'PersonFaceSuggestionResponseDto' });

export class PersonFaceSuggestionResponseDto extends createZodDto(PersonFaceSuggestionResponseSchema) {}

const PersonFaceSuggestionPageResponseSchema = z
  .object({
    suggestions: z.array(PersonFaceSuggestionResponseSchema).describe('Suggested face candidates'),
    hasNextPage: z.boolean().describe('Whether there are more suggestions'),
  })
  .meta({ id: 'PersonFaceSuggestionPageResponseDto' });

export class PersonFaceSuggestionPageResponseDto extends createZodDto(PersonFaceSuggestionPageResponseSchema) {}

const PersonFaceSuggestionFeedbackParamSchema = z
  .object({
    id: z.uuidv4().describe('Person ID'),
    faceId: z.uuidv4().describe('Face ID'),
  })
  .meta({ id: 'PersonFaceSuggestionFeedbackParamDto' });

export class PersonFaceSuggestionFeedbackParamDto extends createZodDto(PersonFaceSuggestionFeedbackParamSchema) {}

const PersonFaceSuggestionFeedbackSchema = z
  .object({
    decision: FaceSuggestionFeedbackDecisionSchema,
  })
  .meta({ id: 'PersonFaceSuggestionFeedbackDto' });

export class PersonFaceSuggestionFeedbackDto extends createZodDto(PersonFaceSuggestionFeedbackSchema) {}

const PersonFaceSuggestionFeedbackResponseSchema = z
  .object({
    id: z.uuidv4().describe('Feedback ID'),
    personId: z.uuidv4().describe('Person ID'),
    faceId: z.uuidv4().describe('Face ID'),
    decision: FaceSuggestionFeedbackDecisionSchema,
    createdAt: z.string().meta({ format: 'date-time' }).describe('Feedback creation timestamp'),
    updatedAt: z.string().meta({ format: 'date-time' }).describe('Feedback update timestamp'),
  })
  .meta({ id: 'PersonFaceSuggestionFeedbackResponseDto' });

export class PersonFaceSuggestionFeedbackResponseDto extends createZodDto(PersonFaceSuggestionFeedbackResponseSchema) {}

const AssetFaceUpdateItemSchema = z
  .object({
    personId: z.uuidv4().describe('Person ID'),
    assetId: z.uuidv4().describe('Asset ID'),
  })
  .meta({ id: 'AssetFaceUpdateItem' });

const AssetFaceUpdateSchema = z
  .object({
    data: z.array(AssetFaceUpdateItemSchema).describe('Face update items'),
  })
  .meta({ id: 'AssetFaceUpdateDto' });

const FaceSchema = z
  .object({
    id: z.uuidv4().describe('Face ID'),
  })
  .meta({ id: 'FaceDto' });

const AssetFaceCreateSchema = AssetFaceUpdateItemSchema.extend({
  imageWidth: z.int().describe('Image width in pixels'),
  imageHeight: z.int().describe('Image height in pixels'),
  x: z.int().describe('Face bounding box X coordinate'),
  y: z.int().describe('Face bounding box Y coordinate'),
  width: z.int().describe('Face bounding box width'),
  height: z.int().describe('Face bounding box height'),
}).meta({ id: 'AssetFaceCreateDto' });

const AssetFaceDeleteSchema = z
  .object({
    force: z.boolean().describe('Force delete even if person has other faces'),
  })
  .meta({ id: 'AssetFaceDeleteDto' });

const PersonStatisticsResponseSchema = z
  .object({
    assets: z.int().describe('Number of assets'),
  })
  .meta({ id: 'PersonStatisticsResponseDto' });

export class AssetFaceUpdateDto extends createZodDto(AssetFaceUpdateSchema) {}
export class FaceDto extends createZodDto(FaceSchema) {}
export class AssetFaceCreateDto extends createZodDto(AssetFaceCreateSchema) {}
export class AssetFaceDeleteDto extends createZodDto(AssetFaceDeleteSchema) {}
export class PersonStatisticsResponseDto extends createZodDto(PersonStatisticsResponseSchema) {}

const PeopleResponseSchema = z
  .object({
    total: z.int().min(0).describe('Total number of people'),
    hidden: z.int().min(0).describe('Number of hidden people'),
    people: z.array(PersonResponseSchema),
    unassignedFaceCount: z.int().min(0).optional().describe('Number of visible faces without an assigned person'),
    unassignedFaces: z
      .array(AssetFaceWithoutPersonResponseSchema)
      .optional()
      .describe('Sample of visible faces without an assigned person'),
    // TODO: make required after a few versions
    hasNextPage: z
      .boolean()
      .optional()
      .describe('Whether there are more pages')
      .meta(new HistoryBuilder().added('v1.110.0').stable('v2').getExtensions()),
  })
  .describe('People response');
export class PeopleResponseDto extends createZodDto(PeopleResponseSchema) {}

export function mapPerson(person: MaybeDehydrated<Person>): PersonResponseDto {
  return {
    id: person.id,
    name: person.name,
    birthDate: asBirthDateString(person.birthDate),
    thumbnailPath: person.thumbnailPath,
    isHidden: person.isHidden,
    isFavorite: person.isFavorite,
    color: person.color ?? undefined,
    updatedAt: asDateString(person.updatedAt),
  };
}

export function mapFacesWithoutPerson(
  face: MaybeDehydrated<Selectable<AssetFaceTable>>,
  edits?: AssetEditActionItem[],
  assetDimensions?: ImageDimensions,
): AssetFaceWithoutPersonResponseDto {
  return {
    id: face.id,
    assetId: face.assetId,
    ...transformFaceBoundingBox(
      {
        boundingBoxX1: face.boundingBoxX1,
        boundingBoxY1: face.boundingBoxY1,
        boundingBoxX2: face.boundingBoxX2,
        boundingBoxY2: face.boundingBoxY2,
        imageWidth: face.imageWidth,
        imageHeight: face.imageHeight,
      },
      edits ?? [],
      assetDimensions ?? { width: face.imageWidth, height: face.imageHeight },
    ),
    sourceType: face.sourceType,
  };
}

export function mapFaces(
  face: AssetFace,
  auth: AuthDto,
  edits?: AssetEditActionItem[],
  assetDimensions?: ImageDimensions,
): AssetFaceResponseDto {
  return {
    ...mapFacesWithoutPerson(face, edits, assetDimensions),
    person: face.person?.ownerId === auth.user.id ? mapPerson(face.person) : null,
  };
}

export function mapFaceSuggestion(
  face: MaybeDehydrated<Selectable<AssetFaceTable>> & { distance: number },
): PersonFaceSuggestionResponseDto {
  return {
    ...mapFacesWithoutPerson(face),
    distance: face.distance,
  };
}

export function mapFaceAssignmentHistory(
  history: Selectable<FaceAssignmentHistoryTable>,
): PersonFaceAssignmentHistoryResponseDto {
  return {
    id: history.id,
    faceId: history.faceId,
    previousPersonId: history.previousPersonId,
    newPersonId: history.newPersonId,
    source: history.source,
    batchId: history.batchId,
    createdAt: asDateString(history.createdAt),
    revertedAt: history.revertedAt ? asDateString(history.revertedAt) : null,
  };
}

export function mapFaceSuggestionFeedback(
  feedback: Selectable<FaceSuggestionFeedbackTable>,
): PersonFaceSuggestionFeedbackResponseDto {
  return {
    id: feedback.id,
    personId: feedback.personId,
    faceId: feedback.faceId,
    decision: feedback.decision,
    createdAt: asDateString(feedback.createdAt),
    updatedAt: asDateString(feedback.updatedAt),
  };
}
