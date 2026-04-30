import { BadRequestException, ConflictException, NotFoundException } from '@nestjs/common';
import { BulkIdErrorReason } from 'src/dtos/asset-ids.response.dto';
import {
  mapFaceAssignmentHistory,
  mapFaces,
  mapFaceSuggestion,
  mapFaceSuggestionFeedback,
  mapPerson,
} from 'src/dtos/person.dto';
import {
  AssetFileType,
  AssetType,
  CacheControl,
  FaceAssignmentHistorySource,
  FaceSuggestionFeedbackDecision,
  JobName,
  JobStatus,
  SourceType,
  SystemMetadataKey,
} from 'src/enum';
import { FaceSearchResult } from 'src/repositories/search.repository';
import { PersonService } from 'src/services/person.service';
import { ImmichFileResponse } from 'src/utils/file';
import { AssetFaceFactory } from 'test/factories/asset-face.factory';
import { AssetFactory } from 'test/factories/asset.factory';
import { AuthFactory } from 'test/factories/auth.factory';
import { PersonFactory } from 'test/factories/person.factory';
import { UserFactory } from 'test/factories/user.factory';
import { authStub } from 'test/fixtures/auth.stub';
import { systemConfigStub } from 'test/fixtures/system-config.stub';
import {
  getAsDetectedFace,
  getForAsset,
  getForAssetFace,
  getForDetectedFaces,
  getForFacialRecognitionJob,
} from 'test/mappers';
import { newDate, newUuid } from 'test/small.factory';
import { makeStream, newTestService, ServiceMocks } from 'test/utils';

const makeFaceAssignmentHistory = (overrides = {}) => ({
  id: newUuid(),
  faceId: newUuid(),
  ownerId: newUuid(),
  actorId: null,
  previousPersonId: null,
  newPersonId: newUuid(),
  source: FaceAssignmentHistorySource.ManualReassign,
  batchId: null,
  createdAt: newDate(),
  revertedAt: null,
  revertedById: null,
  ...overrides,
});

const makeFaceSuggestionFeedback = (overrides = {}) => ({
  id: newUuid(),
  ownerId: newUuid(),
  personId: newUuid(),
  faceId: newUuid(),
  actorId: null,
  decision: FaceSuggestionFeedbackDecision.Rejected,
  createdAt: newDate(),
  updatedAt: newDate(),
  ...overrides,
});

describe(PersonService.name, () => {
  let sut: PersonService;
  let mocks: ServiceMocks;

  beforeEach(() => {
    ({ sut, mocks } = newTestService(PersonService));
  });

  it('should be defined', () => {
    expect(sut).toBeDefined();
  });

  describe('getAll', () => {
    beforeEach(() => {
      mocks.person.getUnassignedFacesForUser.mockResolvedValue([]);
      mocks.person.getUnassignedFaceCountForUser.mockResolvedValue(0);
    });

    it('should get all hidden and visible people with thumbnails', async () => {
      const auth = AuthFactory.create();
      const [person, hiddenPerson] = [PersonFactory.create(), PersonFactory.create({ isHidden: true })];
      const unassignedFace = AssetFaceFactory.create();

      mocks.person.getAllForUser.mockResolvedValue({
        items: [person, hiddenPerson],
        hasNextPage: false,
      });
      mocks.person.getNumberOfPeople.mockResolvedValue({ total: 2, hidden: 1 });
      mocks.person.getUnassignedFacesForUser.mockResolvedValue([unassignedFace]);
      mocks.person.getUnassignedFaceCountForUser.mockResolvedValue(1);
      await expect(sut.getAll(auth, { withHidden: true, page: 1, size: 10 })).resolves.toEqual({
        hasNextPage: false,
        total: 2,
        hidden: 1,
        unassignedFaceCount: 1,
        unassignedFaces: [expect.objectContaining({ id: unassignedFace.id, assetId: unassignedFace.assetId })],
        people: [
          expect.objectContaining({ id: person.id, isHidden: false }),
          expect.objectContaining({
            id: hiddenPerson.id,
            isHidden: true,
          }),
        ],
      });
      expect(mocks.person.getAllForUser).toHaveBeenCalledWith({ skip: 0, take: 10 }, auth.user.id, {
        minimumFaceCount: 3,
        withHidden: true,
      });
      expect(mocks.person.getUnassignedFacesForUser).toHaveBeenCalledWith(auth.user.id, { take: 5 });
      expect(mocks.person.getUnassignedFaceCountForUser).toHaveBeenCalledWith(auth.user.id);
    });

    it('should get all visible people and favorites should be first in the array', async () => {
      const auth = AuthFactory.create();
      const [isFavorite, person] = [PersonFactory.create({ isFavorite: true }), PersonFactory.create()];

      mocks.person.getAllForUser.mockResolvedValue({
        items: [isFavorite, person],
        hasNextPage: false,
      });
      mocks.person.getNumberOfPeople.mockResolvedValue({ total: 2, hidden: 1 });
      await expect(sut.getAll(auth, { withHidden: false, page: 1, size: 10 })).resolves.toEqual({
        hasNextPage: false,
        total: 2,
        hidden: 1,
        unassignedFaceCount: 0,
        unassignedFaces: [],
        people: [
          expect.objectContaining({
            id: isFavorite.id,
            isFavorite: true,
          }),
          expect.objectContaining({ id: person.id, isFavorite: false }),
        ],
      });
      expect(mocks.person.getAllForUser).toHaveBeenCalledWith({ skip: 0, take: 10 }, auth.user.id, {
        minimumFaceCount: 3,
        withHidden: false,
      });
    });
  });

  describe('getById', () => {
    it('should require person.read permission', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();
      mocks.person.getById.mockResolvedValue(person);
      await expect(sut.getById(auth, person.id)).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should throw a bad request when person is not found', async () => {
      const auth = AuthFactory.create();
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set(['unknown']));
      await expect(sut.getById(auth, 'unknown')).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set(['unknown']));
    });

    it('should get a person by id', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      await expect(sut.getById(auth, person.id)).resolves.toEqual(expect.objectContaining({ id: person.id }));
      expect(mocks.person.getById).toHaveBeenCalledWith(person.id);
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });
  });

  describe('getThumbnail', () => {
    it('should require person.read permission', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValue(person);
      await expect(sut.getThumbnail(auth, person.id)).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.storage.createReadStream).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should throw an error when personId is invalid', async () => {
      const auth = AuthFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set(['unknown']));
      await expect(sut.getThumbnail(auth, 'unknown')).rejects.toBeInstanceOf(NotFoundException);
      expect(mocks.storage.createReadStream).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set(['unknown']));
    });

    it('should throw an error when person has no thumbnail', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ thumbnailPath: '' });

      mocks.person.getById.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      await expect(sut.getThumbnail(auth, person.id)).rejects.toBeInstanceOf(NotFoundException);
      expect(mocks.storage.createReadStream).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should serve the thumbnail', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      await expect(sut.getThumbnail(auth, person.id)).resolves.toEqual(
        new ImmichFileResponse({
          path: person.thumbnailPath,
          contentType: 'image/jpeg',
          cacheControl: CacheControl.PrivateWithoutCache,
        }),
      );
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });
  });

  describe('update', () => {
    it('should require person.write permission', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValue(person);
      await expect(sut.update(auth, person.id, { name: 'Person 1' })).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.person.update).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should throw an error when personId is invalid', async () => {
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set());
      await expect(sut.update(authStub.admin, 'person-1', { name: 'Person 1' })).rejects.toBeInstanceOf(
        BadRequestException,
      );
      expect(mocks.person.update).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(authStub.admin.user.id, new Set(['person-1']));
    });

    it("should update a person's name", async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ name: 'Person 1' });

      mocks.person.update.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));

      await expect(sut.update(auth, person.id, { name: 'Person 1' })).resolves.toEqual(
        expect.objectContaining({ id: person.id, name: 'Person 1' }),
      );

      expect(mocks.person.update).toHaveBeenCalledWith({ id: person.id, name: 'Person 1' });
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it("should update a person's date of birth", async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ birthDate: new Date('1976-06-30') });

      mocks.person.update.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));

      await expect(sut.update(auth, person.id, { birthDate: '1976-06-30' })).resolves.toEqual({
        id: person.id,
        name: person.name,
        birthDate: '1976-06-30',
        thumbnailPath: person.thumbnailPath,
        isHidden: false,
        isFavorite: false,
        updatedAt: expect.any(String),
      });
      expect(mocks.person.update).toHaveBeenCalledWith({ id: person.id, birthDate: '1976-06-30' });
      expect(mocks.job.queue).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should update a person visibility', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ isHidden: true });

      mocks.person.update.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));

      await expect(sut.update(auth, person.id, { isHidden: true })).resolves.toEqual(
        expect.objectContaining({ isHidden: true }),
      );

      expect(mocks.person.update).toHaveBeenCalledWith({ id: person.id, isHidden: true });
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should update a person favorite status', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ isFavorite: true });

      mocks.person.update.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));

      await expect(sut.update(auth, person.id, { isFavorite: true })).resolves.toEqual(
        expect.objectContaining({ isFavorite: true }),
      );

      expect(mocks.person.update).toHaveBeenCalledWith({ id: person.id, isFavorite: true });
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it("should update a person's thumbnailPath", async () => {
      const face = AssetFaceFactory.create();
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.update.mockResolvedValue(person);
      mocks.person.getForFeatureFaceUpdate.mockResolvedValue(face);
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([face.assetId]));
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));

      await expect(sut.update(auth, person.id, { featureFaceAssetId: face.assetId })).resolves.toEqual(
        expect.objectContaining({ id: person.id }),
      );

      expect(mocks.person.update).toHaveBeenCalledWith({ id: person.id, faceAssetId: face.id });
      expect(mocks.person.getForFeatureFaceUpdate).toHaveBeenCalledWith({
        assetId: face.assetId,
        personId: person.id,
      });
      expect(mocks.job.queue).toHaveBeenCalledWith({
        name: JobName.PersonGenerateThumbnail,
        data: { id: person.id },
      });
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it("should update a person's thumbnailPath by face id", async () => {
      const face = AssetFaceFactory.create();
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.update.mockResolvedValue(person);
      mocks.person.getForFeatureFaceUpdateByFaceId.mockResolvedValue(face);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.access.person.checkFaceOwnerAccess.mockResolvedValue(new Set([face.id]));

      await expect(sut.update(auth, person.id, { featureFaceId: face.id })).resolves.toEqual(
        expect.objectContaining({ id: person.id }),
      );

      expect(mocks.person.update).toHaveBeenCalledWith({ id: person.id, faceAssetId: face.id });
      expect(mocks.person.getForFeatureFaceUpdateByFaceId).toHaveBeenCalledWith({
        faceId: face.id,
        personId: person.id,
      });
      expect(mocks.job.queue).toHaveBeenCalledWith({
        name: JobName.PersonGenerateThumbnail,
        data: { id: person.id },
      });
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
      expect(mocks.access.person.checkFaceOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([face.id]));
    });

    it('should throw an error when both feature face fields are provided', async () => {
      const face = AssetFaceFactory.create();
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));

      await expect(
        sut.update(auth, person.id, { featureFaceAssetId: face.assetId, featureFaceId: face.id }),
      ).rejects.toThrow(BadRequestException);
      expect(mocks.person.update).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should throw an error when the face feature assetId is invalid', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValue(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));

      await expect(sut.update(auth, person.id, { featureFaceAssetId: '-1' })).rejects.toThrow(BadRequestException);
      expect(mocks.person.update).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should throw an error when the feature faceId is invalid', async () => {
      const face = AssetFaceFactory.create();
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getForFeatureFaceUpdateByFaceId.mockResolvedValue(void 0);
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.access.person.checkFaceOwnerAccess.mockResolvedValue(new Set([face.id]));

      await expect(sut.update(auth, person.id, { featureFaceId: face.id })).rejects.toThrow(BadRequestException);
      expect(mocks.person.update).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
      expect(mocks.access.person.checkFaceOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([face.id]));
    });
  });

  describe('updateAll', () => {
    it('should throw an error when personId is invalid', async () => {
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set());

      await expect(sut.updateAll(authStub.admin, { people: [{ id: 'person-1', name: 'Person 1' }] })).resolves.toEqual([
        { error: BulkIdErrorReason.UNKNOWN, id: 'person-1', success: false },
      ]);
      expect(mocks.person.update).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(authStub.admin.user.id, new Set(['person-1']));
    });
  });

  describe('reassignFaces', () => {
    it('should throw an error if user has no access to the person', async () => {
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set());

      await expect(
        sut.reassignFaces(AuthFactory.create(), 'person-id', {
          data: [{ personId: 'asset-face-1', assetId: '' }],
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.job.queue).not.toHaveBeenCalledWith();
      expect(mocks.job.queueAll).not.toHaveBeenCalledWith();
    });

    it('should reassign a face', async () => {
      const face = AssetFaceFactory.create();
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getById.mockResolvedValue(person);
      mocks.access.person.checkFaceOwnerAccess.mockResolvedValue(new Set([face.id]));
      mocks.person.getFacesByIds.mockResolvedValue([getForAssetFace(face)]);
      mocks.person.getRandomFace.mockResolvedValue(AssetFaceFactory.create());
      mocks.person.refreshFaces.mockResolvedValue();
      mocks.person.reassignFaceWithHistory.mockResolvedValue({
        faceId: face.id,
        previousPersonId: null,
        newPersonId: person.id,
        history: makeFaceAssignmentHistory({
          faceId: face.id,
          ownerId: auth.user.id,
          newPersonId: person.id,
          source: FaceAssignmentHistorySource.ManualBulkReassign,
        }),
      });
      mocks.person.update.mockResolvedValue(person);

      await expect(
        sut.reassignFaces(auth, person.id, {
          data: [{ personId: person.id, assetId: face.assetId }],
        }),
      ).resolves.toBeDefined();

      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.PersonGenerateThumbnail,
          data: { id: person.id },
        },
      ]);
      expect(mocks.person.reassignFaceWithHistory).toHaveBeenCalledWith({
        faceId: face.id,
        newPersonId: person.id,
        ownerId: auth.user.id,
        actorId: auth.user.id,
        source: FaceAssignmentHistorySource.ManualBulkReassign,
      });
    });
  });

  describe('handlePersonMigration', () => {
    it('should not move person files', async () => {
      await expect(sut.handlePersonMigration(PersonFactory.create())).resolves.toBe(JobStatus.Failed);
    });
  });

  describe('getFacesById', () => {
    it('should get the bounding boxes for an asset', async () => {
      const auth = AuthFactory.create();
      const face = AssetFaceFactory.create();
      const asset = AssetFactory.from({ id: face.assetId }).exif().build();
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([asset.id]));
      mocks.person.getFaces.mockResolvedValue([getForAssetFace(face)]);
      mocks.asset.getForFaces.mockResolvedValue({ edits: [], ...asset.exifInfo });
      await expect(sut.getFacesById(auth, { id: face.assetId })).resolves.toStrictEqual([
        mapFaces(getForAssetFace(face), auth),
      ]);
    });

    it('should reject if the user has not access to the asset', async () => {
      const face = AssetFaceFactory.create();
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set());
      mocks.person.getFaces.mockResolvedValue([getForAssetFace(face)]);
      await expect(sut.getFacesById(AuthFactory.create(), { id: face.assetId })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    });
  });

  describe('getFacesByPersonId', () => {
    it('should get visible face references for a person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });
      const face = getForAssetFace(AssetFaceFactory.from().person({ id: person.id, ownerId: auth.user.id }).build());

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFacesForPerson.mockResolvedValue({ items: [face], hasNextPage: false });

      await expect(sut.getFacesByPersonId(auth, person.id, { page: 2, size: 10 })).resolves.toStrictEqual({
        faces: [mapFaces(face, auth)],
        hasNextPage: false,
      });

      expect(mocks.person.getFacesForPerson).toHaveBeenCalledWith({ take: 10, skip: 10 }, person.id);
    });

    it('should reject if the user has no access to the person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set());

      await expect(sut.getFacesByPersonId(auth, person.id, { page: 1, size: 10 })).rejects.toBeInstanceOf(
        BadRequestException,
      );
      expect(mocks.person.getFacesForPerson).not.toHaveBeenCalled();
    });
  });

  describe('getFaceAssignmentHistory', () => {
    it('should get face assignment history for a person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });
      const history = makeFaceAssignmentHistory({
        ownerId: auth.user.id,
        previousPersonId: null,
        newPersonId: person.id,
      });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceAssignmentHistoryForPerson.mockResolvedValue({ items: [history], hasNextPage: false });

      await expect(sut.getFaceAssignmentHistory(auth, person.id, { page: 2, size: 10 })).resolves.toEqual({
        history: [mapFaceAssignmentHistory(history)],
        hasNextPage: false,
      });

      expect(mocks.person.getFaceAssignmentHistoryForPerson).toHaveBeenCalledWith(
        { take: 10, skip: 10 },
        auth.user.id,
        person.id,
      );
    });

    it('should reject if the user has no access to the person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set());

      await expect(sut.getFaceAssignmentHistory(auth, person.id, { page: 1, size: 10 })).rejects.toBeInstanceOf(
        BadRequestException,
      );
      expect(mocks.person.getFaceAssignmentHistoryForPerson).not.toHaveBeenCalled();
    });
  });

  describe('getFaceSuggestions', () => {
    it('should get face suggestions for a person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });
      const suggestion = { ...AssetFaceFactory.create(), distance: 0.22 };

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceSuggestionsForPerson.mockResolvedValue({
        items: [{ ...suggestion, total: 1 }],
        hasNextPage: false,
      });

      await expect(sut.getFaceSuggestions(auth, person.id, { page: 2, size: 5 })).resolves.toEqual({
        suggestions: [mapFaceSuggestion(suggestion)],
        hasNextPage: false,
        total: 1,
      });

      expect(mocks.person.getFaceSuggestionsForPerson).toHaveBeenCalledWith(
        { take: 5, skip: 5 },
        auth.user.id,
        person.id,
        {
          maxDistance: expect.any(Number),
          referenceFaceLimit: 10,
        },
      );
    });

    it('should use suggestion distance instead of automatic recognition distance by default', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });

      mocks.systemMetadata.get.mockResolvedValue({
        machineLearning: {
          facialRecognition: {
            maxDistance: 0.5,
            suggestionMaxDistance: 1.05,
          },
        },
      });
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceSuggestionsForPerson.mockResolvedValue({ items: [], hasNextPage: false });

      await expect(sut.getFaceSuggestions(auth, person.id, { page: 1, size: 5 })).resolves.toMatchObject({
        total: 0,
      });

      expect(mocks.person.getFaceSuggestionsForPerson).toHaveBeenCalledWith(
        { take: 5, skip: 0 },
        auth.user.id,
        person.id,
        {
          maxDistance: 1.05,
          referenceFaceLimit: 10,
        },
      );
    });

    it('should reject if the user has no access to the person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set());

      await expect(sut.getFaceSuggestions(auth, person.id, { page: 1, size: 10 })).rejects.toBeInstanceOf(
        BadRequestException,
      );
      expect(mocks.person.getFaceSuggestionsForPerson).not.toHaveBeenCalled();
    });
  });

  describe('getFaceSuggestionSummary', () => {
    it('should scan visible people and return the first pending suggestion per person', async () => {
      const auth = AuthFactory.create();
      const [person1, person2, person3] = [
        PersonFactory.create({ ownerId: auth.user.id }),
        PersonFactory.create({ ownerId: auth.user.id }),
        PersonFactory.create({ ownerId: auth.user.id }),
      ];
      const [suggestion1, suggestion3] = [
        { ...AssetFaceFactory.create(), distance: 0.72 },
        { ...AssetFaceFactory.create(), distance: 0.88 },
      ];

      mocks.systemMetadata.get.mockResolvedValue({
        machineLearning: {
          facialRecognition: {
            minFaces: 3,
            maxDistance: 0.5,
            suggestionMaxDistance: 1,
          },
        },
      });
      mocks.person.getAllForUser.mockResolvedValue({ items: [person1, person2, person3], hasNextPage: true });
      mocks.person.getFaceSuggestionsForPerson
        .mockResolvedValueOnce({ items: [{ ...suggestion1, total: 1 }], hasNextPage: false })
        .mockResolvedValueOnce({ items: [], hasNextPage: false })
        .mockResolvedValueOnce({ items: [{ ...suggestion3, total: 1 }], hasNextPage: false });

      await expect(sut.getFaceSuggestionSummary(auth, { size: 1, peopleLimit: 50 })).resolves.toEqual({
        people: [
          {
            person: mapPerson(person1),
            suggestion: mapFaceSuggestion(suggestion1),
          },
        ],
        pendingPeople: 2,
        scannedPeople: 3,
        hasMorePeople: true,
      });

      expect(mocks.person.getAllForUser).toHaveBeenCalledWith({ take: 50, skip: 0 }, auth.user.id, {
        minimumFaceCount: 3,
        withHidden: false,
      });
      expect(mocks.person.getFaceSuggestionsForPerson).toHaveBeenCalledWith(
        { take: 1, skip: 0 },
        auth.user.id,
        person1.id,
        {
          maxDistance: 1,
          referenceFaceLimit: 10,
        },
      );
    });
  });

  describe('respondToFaceSuggestion', () => {
    it('should accept an unassigned suggested face', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id, faceAssetId: null });
      const face = AssetFaceFactory.create();
      const feedback = makeFaceSuggestionFeedback({
        ownerId: auth.user.id,
        personId: person.id,
        faceId: face.id,
        actorId: auth.user.id,
        decision: FaceSuggestionFeedbackDecision.Accepted,
      });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceForSuggestionFeedback.mockResolvedValue({ id: face.id, personId: null });
      mocks.person.getById.mockResolvedValue(person);
      mocks.person.reassignFaceWithHistory.mockResolvedValue({
        faceId: face.id,
        previousPersonId: null,
        newPersonId: person.id,
        history: makeFaceAssignmentHistory({
          faceId: face.id,
          ownerId: auth.user.id,
          newPersonId: person.id,
          source: FaceAssignmentHistorySource.SuggestionAccepted,
        }),
      });
      mocks.person.getRandomFace.mockResolvedValue(face);
      mocks.person.update.mockResolvedValue({ ...person, faceAssetId: face.id });
      mocks.person.upsertFaceSuggestionFeedback.mockResolvedValue(feedback);

      await expect(
        sut.respondToFaceSuggestion(auth, person.id, face.id, {
          decision: FaceSuggestionFeedbackDecision.Accepted,
        }),
      ).resolves.toEqual(mapFaceSuggestionFeedback(feedback));

      expect(mocks.person.reassignFaceWithHistory).toHaveBeenCalledWith({
        faceId: face.id,
        newPersonId: person.id,
        ownerId: auth.user.id,
        actorId: auth.user.id,
        source: FaceAssignmentHistorySource.SuggestionAccepted,
      });
      expect(mocks.person.upsertFaceSuggestionFeedback).toHaveBeenCalledWith({
        ownerId: auth.user.id,
        personId: person.id,
        faceId: face.id,
        actorId: auth.user.id,
        decision: FaceSuggestionFeedbackDecision.Accepted,
      });
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        { name: JobName.PersonGenerateThumbnail, data: { id: person.id } },
      ]);
    });

    it('should reject an unassigned suggested face without reassigning it', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });
      const face = AssetFaceFactory.create();
      const feedback = makeFaceSuggestionFeedback({
        ownerId: auth.user.id,
        personId: person.id,
        faceId: face.id,
        actorId: auth.user.id,
        decision: FaceSuggestionFeedbackDecision.Rejected,
      });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceForSuggestionFeedback.mockResolvedValue({ id: face.id, personId: null });
      mocks.person.upsertFaceSuggestionFeedback.mockResolvedValue(feedback);

      await expect(
        sut.respondToFaceSuggestion(auth, person.id, face.id, {
          decision: FaceSuggestionFeedbackDecision.Rejected,
        }),
      ).resolves.toEqual(mapFaceSuggestionFeedback(feedback));

      expect(mocks.person.reassignFaceWithHistory).not.toHaveBeenCalled();
      expect(mocks.person.upsertFaceSuggestionFeedback).toHaveBeenCalledWith({
        ownerId: auth.user.id,
        personId: person.id,
        faceId: face.id,
        actorId: auth.user.id,
        decision: FaceSuggestionFeedbackDecision.Rejected,
      });
    });

    it('should throw conflict if a suggested face was assigned to another person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });
      const otherPerson = PersonFactory.create({ ownerId: auth.user.id });
      const face = AssetFaceFactory.create({ personId: otherPerson.id });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceForSuggestionFeedback.mockResolvedValue({ id: face.id, personId: otherPerson.id });

      await expect(
        sut.respondToFaceSuggestion(auth, person.id, face.id, {
          decision: FaceSuggestionFeedbackDecision.Accepted,
        }),
      ).rejects.toBeInstanceOf(ConflictException);

      expect(mocks.person.reassignFaceWithHistory).not.toHaveBeenCalled();
      expect(mocks.person.upsertFaceSuggestionFeedback).not.toHaveBeenCalled();
    });
  });

  describe('respondToFaceSuggestions', () => {
    it('should accept multiple suggested faces and report partial failures', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id, faceAssetId: newUuid() });
      const otherPerson = PersonFactory.create({ ownerId: auth.user.id });
      const acceptedFace = AssetFaceFactory.create();
      const assignedFace = AssetFaceFactory.create({ personId: otherPerson.id });
      const feedback = makeFaceSuggestionFeedback({
        ownerId: auth.user.id,
        personId: person.id,
        faceId: acceptedFace.id,
        actorId: auth.user.id,
        decision: FaceSuggestionFeedbackDecision.Accepted,
      });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getById.mockResolvedValue(person);
      mocks.person.getFaceForSuggestionFeedback
        .mockResolvedValueOnce({ id: acceptedFace.id, personId: null })
        .mockResolvedValueOnce({ id: assignedFace.id, personId: otherPerson.id });
      mocks.person.reassignFaceWithHistory.mockResolvedValue({
        faceId: acceptedFace.id,
        previousPersonId: null,
        newPersonId: person.id,
        history: makeFaceAssignmentHistory({
          faceId: acceptedFace.id,
          ownerId: auth.user.id,
          newPersonId: person.id,
          source: FaceAssignmentHistorySource.SuggestionAccepted,
        }),
      });
      mocks.person.upsertFaceSuggestionFeedback.mockResolvedValue(feedback);

      await expect(
        sut.respondToFaceSuggestions(auth, person.id, {
          faceIds: [acceptedFace.id, assignedFace.id],
          decision: FaceSuggestionFeedbackDecision.Accepted,
        }),
      ).resolves.toEqual({
        results: [mapFaceSuggestionFeedback(feedback)],
        failed: [{ faceId: assignedFace.id, reason: 'Face suggestion is no longer unassigned' }],
      });

      expect(mocks.person.getById).toHaveBeenCalledTimes(1);
      expect(mocks.person.reassignFaceWithHistory).toHaveBeenCalledTimes(1);
      expect(mocks.person.reassignFaceWithHistory).toHaveBeenCalledWith({
        faceId: acceptedFace.id,
        newPersonId: person.id,
        ownerId: auth.user.id,
        actorId: auth.user.id,
        source: FaceAssignmentHistorySource.SuggestionAccepted,
      });
      expect(mocks.person.upsertFaceSuggestionFeedback).toHaveBeenCalledTimes(1);
    });

    it('should reject unique suggested faces in bulk without reassigning them', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });
      const face1 = AssetFaceFactory.create();
      const face2 = AssetFaceFactory.create();
      const feedback1 = makeFaceSuggestionFeedback({
        ownerId: auth.user.id,
        personId: person.id,
        faceId: face1.id,
        actorId: auth.user.id,
        decision: FaceSuggestionFeedbackDecision.Rejected,
      });
      const feedback2 = makeFaceSuggestionFeedback({
        ownerId: auth.user.id,
        personId: person.id,
        faceId: face2.id,
        actorId: auth.user.id,
        decision: FaceSuggestionFeedbackDecision.Rejected,
      });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceForSuggestionFeedback
        .mockResolvedValueOnce({ id: face1.id, personId: null })
        .mockResolvedValueOnce({ id: face2.id, personId: null });
      mocks.person.upsertFaceSuggestionFeedback.mockResolvedValueOnce(feedback1).mockResolvedValueOnce(feedback2);

      await expect(
        sut.respondToFaceSuggestions(auth, person.id, {
          faceIds: [face1.id, face1.id, face2.id],
          decision: FaceSuggestionFeedbackDecision.Rejected,
        }),
      ).resolves.toEqual({
        results: [mapFaceSuggestionFeedback(feedback1), mapFaceSuggestionFeedback(feedback2)],
        failed: [],
      });

      expect(mocks.person.getFaceForSuggestionFeedback).toHaveBeenCalledTimes(2);
      expect(mocks.person.reassignFaceWithHistory).not.toHaveBeenCalled();
      expect(mocks.person.upsertFaceSuggestionFeedback).toHaveBeenCalledTimes(2);
    });
  });

  describe('revertFaceAssignmentHistory', () => {
    it('should revert a face assignment history entry', async () => {
      const auth = AuthFactory.create();
      const face = AssetFaceFactory.create();
      const previousPerson = PersonFactory.create({ ownerId: auth.user.id, faceAssetId: newUuid() });
      const currentPerson = PersonFactory.create({ ownerId: auth.user.id, faceAssetId: newUuid() });
      const history = makeFaceAssignmentHistory({
        faceId: face.id,
        ownerId: auth.user.id,
        previousPersonId: previousPerson.id,
        newPersonId: currentPerson.id,
        revertedAt: newDate(),
        revertedById: auth.user.id,
      });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([currentPerson.id]));
      mocks.person.revertFaceAssignmentHistory.mockResolvedValue({
        status: 'reverted',
        history,
        faceId: face.id,
        fromPersonId: currentPerson.id,
        toPersonId: previousPerson.id,
      });
      mocks.person.getById.mockResolvedValueOnce(previousPerson).mockResolvedValueOnce(currentPerson);

      await expect(sut.revertFaceAssignmentHistory(auth, currentPerson.id, history.id)).resolves.toEqual(
        mapFaceAssignmentHistory(history),
      );

      expect(mocks.person.revertFaceAssignmentHistory).toHaveBeenCalledWith(
        history.id,
        auth.user.id,
        currentPerson.id,
        auth.user.id,
      );
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
    });

    it('should throw conflict when the history entry cannot be reverted safely', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });
      const history = makeFaceAssignmentHistory({ ownerId: auth.user.id, newPersonId: person.id });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.revertFaceAssignmentHistory.mockResolvedValue({ status: 'conflict', history });

      await expect(sut.revertFaceAssignmentHistory(auth, person.id, history.id)).rejects.toBeInstanceOf(
        ConflictException,
      );
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
    });

    it('should throw not found when the history entry does not belong to the person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create({ ownerId: auth.user.id });

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.revertFaceAssignmentHistory.mockResolvedValue({ status: 'not-found' });

      await expect(sut.revertFaceAssignmentHistory(auth, person.id, newUuid())).rejects.toBeInstanceOf(
        NotFoundException,
      );
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
    });
  });

  describe('createFace', () => {
    it('should create a manual face and initialize the person feature photo creation', async () => {
      const auth = AuthFactory.create();
      const asset = AssetFactory.create();
      const person = PersonFactory.create({ faceAssetId: null });
      const featureFace = AssetFaceFactory.create({
        assetId: asset.id,
        personId: person.id,
        sourceType: SourceType.Manual,
      });

      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([asset.id]));
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.asset.getById.mockResolvedValue(getForAsset(asset));
      mocks.person.getById.mockResolvedValue(person);
      mocks.person.getRandomFace.mockResolvedValue(featureFace);
      mocks.person.update.mockResolvedValue({ ...person, faceAssetId: featureFace.id });

      await expect(
        sut.createFace(auth, {
          assetId: asset.id,
          personId: person.id,
          imageHeight: 500,
          imageWidth: 400,
          x: 10,
          y: 20,
          width: 100,
          height: 110,
        }),
      ).resolves.toBeUndefined();

      expect(mocks.asset.getById).toHaveBeenCalledWith(asset.id, { edits: true, exifInfo: true });
      expect(mocks.person.createAssetFace).toHaveBeenCalledWith({
        assetId: asset.id,
        personId: person.id,
        imageHeight: 500,
        imageWidth: 400,
        boundingBoxX1: 10,
        boundingBoxX2: 110,
        boundingBoxY1: 20,
        boundingBoxY2: 130,
        sourceType: SourceType.Manual,
      });
      expect(mocks.person.getRandomFace).toHaveBeenCalledWith(person.id);
      expect(mocks.person.update).toHaveBeenCalledWith({ id: person.id, faceAssetId: featureFace.id });
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        { name: JobName.PersonGenerateThumbnail, data: { id: person.id } },
      ]);
    });

    it('should not update the person feature photo if one already exists', async () => {
      const auth = AuthFactory.create();
      const asset = AssetFactory.create();
      const person = PersonFactory.create({ faceAssetId: newUuid() });

      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([asset.id]));
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.asset.getById.mockResolvedValue(getForAsset(asset));
      mocks.person.getById.mockResolvedValue(person);

      await expect(
        sut.createFace(auth, {
          assetId: asset.id,
          personId: person.id,
          imageHeight: 500,
          imageWidth: 400,
          x: 10,
          y: 20,
          width: 100,
          height: 110,
        }),
      ).resolves.toBeUndefined();

      expect(mocks.person.createAssetFace).toHaveBeenCalledOnce();
      expect(mocks.person.getRandomFace).not.toHaveBeenCalled();
      expect(mocks.person.update).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
    });
  });

  describe('createNewFeaturePhoto', () => {
    it('should change person feature photo', async () => {
      const person = PersonFactory.create();

      mocks.person.getRandomFace.mockResolvedValue(AssetFaceFactory.create());
      await sut.createNewFeaturePhoto([person.id]);
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.PersonGenerateThumbnail,
          data: { id: person.id },
        },
      ]);
    });
  });

  describe('reassignFacesById', () => {
    it('should create a new person', async () => {
      const face = AssetFaceFactory.create();
      const person = PersonFactory.create({ faceAssetId: newUuid() });
      const auth = AuthFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.access.person.checkFaceOwnerAccess.mockResolvedValue(new Set([face.id]));
      mocks.person.getFaceById.mockResolvedValue(getForAssetFace(face));
      mocks.person.reassignFaceWithHistory.mockResolvedValue({
        faceId: face.id,
        previousPersonId: null,
        newPersonId: person.id,
        history: makeFaceAssignmentHistory({
          faceId: face.id,
          ownerId: auth.user.id,
          newPersonId: person.id,
          source: FaceAssignmentHistorySource.ManualReassign,
        }),
      });
      mocks.person.getById.mockResolvedValue(person);
      await expect(sut.reassignFacesById(auth, person.id, { id: face.id })).resolves.toEqual({
        birthDate: person.birthDate,
        isHidden: person.isHidden,
        isFavorite: person.isFavorite,
        id: person.id,
        name: person.name,
        thumbnailPath: person.thumbnailPath,
        updatedAt: expect.any(String),
      });

      expect(mocks.person.reassignFaceWithHistory).toHaveBeenCalledWith({
        faceId: face.id,
        newPersonId: person.id,
        ownerId: auth.user.id,
        actorId: auth.user.id,
        source: FaceAssignmentHistorySource.ManualReassign,
      });
      expect(mocks.job.queue).not.toHaveBeenCalledWith();
      expect(mocks.job.queueAll).not.toHaveBeenCalledWith();
    });

    it('should fail if user has not the correct permissions on the asset', async () => {
      const face = AssetFaceFactory.create();
      const person = PersonFactory.create();

      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      mocks.person.getFaceById.mockResolvedValue(getForAssetFace(face));
      mocks.person.getById.mockResolvedValue(person);
      await expect(
        sut.reassignFacesById(AuthFactory.create(), person.id, {
          id: face.id,
        }),
      ).rejects.toBeInstanceOf(BadRequestException);

      expect(mocks.job.queue).not.toHaveBeenCalledWith();
      expect(mocks.job.queueAll).not.toHaveBeenCalledWith();
    });
  });

  describe('createPerson', () => {
    it('should create a new person', async () => {
      const auth = AuthFactory.create();

      mocks.person.create.mockResolvedValue(PersonFactory.create());
      await expect(sut.create(auth, {})).resolves.toBeDefined();

      expect(mocks.person.create).toHaveBeenCalledWith({ ownerId: auth.user.id });
    });
  });

  describe('handlePersonCleanup', () => {
    it('should delete people without faces', async () => {
      const person = PersonFactory.create();

      mocks.person.getAllWithoutFaces.mockResolvedValue([person]);

      await sut.handlePersonCleanup();

      expect(mocks.person.delete).toHaveBeenCalledWith([person.id]);
      expect(mocks.storage.unlink).toHaveBeenCalledWith(person.thumbnailPath);
    });
  });

  describe('handleQueueDetectFaces', () => {
    it('should skip if machine learning is disabled', async () => {
      mocks.systemMetadata.get.mockResolvedValue(systemConfigStub.machineLearningDisabled);

      await expect(sut.handleQueueDetectFaces({})).resolves.toBe(JobStatus.Skipped);
      expect(mocks.job.queue).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.systemMetadata.get).toHaveBeenCalled();
    });

    it('should queue missing assets', async () => {
      const asset = AssetFactory.create();
      mocks.assetJob.streamForDetectFacesJob.mockReturnValue(makeStream([asset]));

      await sut.handleQueueDetectFaces({ force: false });

      expect(mocks.assetJob.streamForDetectFacesJob).toHaveBeenCalledWith(false, false);
      expect(mocks.person.vacuum).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.AssetDetectFaces,
          data: { id: asset.id },
        },
      ]);
    });

    it('should queue all assets', async () => {
      const asset = AssetFactory.create();
      const person = PersonFactory.create();

      mocks.assetJob.streamForDetectFacesJob.mockReturnValue(makeStream([asset]));
      mocks.person.deleteMachineLearningFacesAndFrames.mockResolvedValue(['/data/thumbs/frame.jpeg']);
      mocks.person.getAllWithoutFaces.mockResolvedValue([person]);

      await sut.handleQueueDetectFaces({ force: true });

      expect(mocks.person.deleteMachineLearningFacesAndFrames).toHaveBeenCalled();
      expect(mocks.person.delete).toHaveBeenCalledWith([person.id]);
      expect(mocks.person.vacuum).toHaveBeenCalledWith({ reindexVectors: true });
      expect(mocks.storage.unlink).toHaveBeenCalledWith('/data/thumbs/frame.jpeg');
      expect(mocks.storage.unlink).toHaveBeenCalledWith(person.thumbnailPath);
      expect(mocks.assetJob.streamForDetectFacesJob).toHaveBeenCalledWith(true, false);
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.AssetDetectFaces,
          data: { id: asset.id },
        },
      ]);
    });

    it('should refresh all assets', async () => {
      const asset = AssetFactory.create();
      mocks.assetJob.streamForDetectFacesJob.mockReturnValue(makeStream([asset]));

      await sut.handleQueueDetectFaces({ force: undefined });

      expect(mocks.person.delete).not.toHaveBeenCalled();
      expect(mocks.person.deleteFaces).not.toHaveBeenCalled();
      expect(mocks.person.vacuum).not.toHaveBeenCalled();
      expect(mocks.storage.unlink).not.toHaveBeenCalled();
      expect(mocks.assetJob.streamForDetectFacesJob).toHaveBeenCalledWith(undefined, false);
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.AssetDetectFaces,
          data: { id: asset.id },
        },
      ]);
      expect(mocks.job.queue).toHaveBeenCalledWith({ name: JobName.PersonCleanup });
    });

    it('should delete existing people and faces if forced', async () => {
      const asset = AssetFactory.create();
      const face = AssetFaceFactory.from().person().build();
      const person = PersonFactory.create();

      mocks.person.getAll.mockReturnValue(makeStream([face.person!, person]));
      mocks.person.getAllFaces.mockReturnValue(makeStream([face]));
      mocks.assetJob.streamForDetectFacesJob.mockReturnValue(makeStream([asset]));
      mocks.person.getAllWithoutFaces.mockResolvedValue([person]);
      mocks.person.deleteMachineLearningFacesAndFrames.mockResolvedValue([]);

      await sut.handleQueueDetectFaces({ force: true });

      expect(mocks.assetJob.streamForDetectFacesJob).toHaveBeenCalledWith(true, false);
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.AssetDetectFaces,
          data: { id: asset.id },
        },
      ]);
      expect(mocks.person.delete).toHaveBeenCalledWith([person.id]);
      expect(mocks.storage.unlink).toHaveBeenCalledWith(person.thumbnailPath);
      expect(mocks.person.vacuum).toHaveBeenCalledWith({ reindexVectors: true });
    });

    it('should include videos without previews when video indexing is enabled', async () => {
      const asset = AssetFactory.create();
      mocks.systemMetadata.get.mockResolvedValue({
        machineLearning: {
          facialRecognition: {
            video: { enabled: true, intervalSeconds: 5, maxFramesPerVideo: 30, downscaleLongEdge: 1440 },
          },
        },
      });
      mocks.assetJob.streamForDetectFacesJob.mockReturnValue(makeStream([asset]));

      await sut.handleQueueDetectFaces({ force: false });

      expect(mocks.assetJob.streamForDetectFacesJob).toHaveBeenCalledWith(false, true);
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.AssetDetectFaces,
          data: { id: asset.id },
        },
      ]);
    });
  });

  describe('handleQueueRecognizeFaces', () => {
    it('should skip if machine learning is disabled', async () => {
      mocks.job.getJobCounts.mockResolvedValue({
        active: 1,
        waiting: 0,
        paused: 0,
        completed: 0,
        failed: 0,
        delayed: 0,
      });
      mocks.systemMetadata.get.mockResolvedValue(systemConfigStub.machineLearningDisabled);

      await expect(sut.handleQueueRecognizeFaces({})).resolves.toBe(JobStatus.Skipped);
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.systemMetadata.get).toHaveBeenCalled();
      expect(mocks.systemMetadata.set).not.toHaveBeenCalled();
    });

    it('should skip if recognition jobs are already queued', async () => {
      mocks.job.getJobCounts.mockResolvedValue({
        active: 1,
        waiting: 1,
        paused: 0,
        completed: 0,
        failed: 0,
        delayed: 0,
      });

      await expect(sut.handleQueueRecognizeFaces({})).resolves.toBe(JobStatus.Skipped);
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.systemMetadata.set).not.toHaveBeenCalled();
    });

    it('should queue missing assets', async () => {
      const face = AssetFaceFactory.create();
      mocks.job.getJobCounts.mockResolvedValue({
        active: 1,
        waiting: 0,
        paused: 0,
        completed: 0,
        failed: 0,
        delayed: 0,
      });
      mocks.person.getAllFaces.mockReturnValue(makeStream([face]));
      mocks.person.getAllWithoutFaces.mockResolvedValue([]);

      await sut.handleQueueRecognizeFaces({});

      expect(mocks.person.getAllFaces).toHaveBeenCalledWith({
        personId: null,
        sourceType: SourceType.MachineLearning,
      });
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.FacialRecognition,
          data: { id: face.id, deferred: false },
        },
      ]);
      expect(mocks.systemMetadata.set).toHaveBeenCalledWith(SystemMetadataKey.FacialRecognitionState, {
        lastRun: expect.any(String),
      });
      expect(mocks.person.vacuum).not.toHaveBeenCalled();
    });

    it('should queue all assets', async () => {
      const face = AssetFaceFactory.create();
      mocks.job.getJobCounts.mockResolvedValue({
        active: 1,
        waiting: 0,
        paused: 0,
        completed: 0,
        failed: 0,
        delayed: 0,
      });
      mocks.person.getAll.mockReturnValue(makeStream());
      mocks.person.getAllFaces.mockReturnValue(makeStream([face]));
      mocks.person.getAllWithoutFaces.mockResolvedValue([]);

      await sut.handleQueueRecognizeFaces({ force: true });

      expect(mocks.person.getAllFaces).toHaveBeenCalledWith(undefined);
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.FacialRecognition,
          data: { id: face.id, deferred: false },
        },
      ]);
      expect(mocks.systemMetadata.set).toHaveBeenCalledWith(SystemMetadataKey.FacialRecognitionState, {
        lastRun: expect.any(String),
      });
      expect(mocks.person.vacuum).toHaveBeenCalledWith({ reindexVectors: false });
    });

    it('should run nightly if new face has been added since last run', async () => {
      const face = AssetFaceFactory.create();
      mocks.person.getLatestFaceDate.mockResolvedValue(new Date().toISOString());
      mocks.person.getAllFaces.mockReturnValue(makeStream([face]));
      mocks.job.getJobCounts.mockResolvedValue({
        active: 1,
        waiting: 0,
        paused: 0,
        completed: 0,
        failed: 0,
        delayed: 0,
      });
      mocks.person.getAll.mockReturnValue(makeStream());
      mocks.person.getAllFaces.mockReturnValue(makeStream([face]));
      mocks.person.getAllWithoutFaces.mockResolvedValue([]);
      mocks.person.unassignFaces.mockResolvedValue();

      await sut.handleQueueRecognizeFaces({ force: false, nightly: true });

      expect(mocks.systemMetadata.get).toHaveBeenCalledWith(SystemMetadataKey.FacialRecognitionState);
      expect(mocks.person.getLatestFaceDate).toHaveBeenCalledOnce();
      expect(mocks.person.getAllFaces).toHaveBeenCalledWith({
        personId: null,
        sourceType: SourceType.MachineLearning,
      });
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.FacialRecognition,
          data: { id: face.id, deferred: false },
        },
      ]);
      expect(mocks.systemMetadata.set).toHaveBeenCalledWith(SystemMetadataKey.FacialRecognitionState, {
        lastRun: expect.any(String),
      });
      expect(mocks.person.vacuum).not.toHaveBeenCalled();
    });

    it('should skip nightly if no new face has been added since last run', async () => {
      const lastRun = new Date();

      mocks.systemMetadata.get.mockResolvedValue({ lastRun: lastRun.toISOString() });
      mocks.person.getLatestFaceDate.mockResolvedValue(new Date(lastRun.getTime() - 1).toISOString());
      mocks.person.getAllFaces.mockReturnValue(makeStream([AssetFaceFactory.create()]));
      mocks.person.getAllWithoutFaces.mockResolvedValue([]);

      await sut.handleQueueRecognizeFaces({ force: true, nightly: true });

      expect(mocks.systemMetadata.get).toHaveBeenCalledWith(SystemMetadataKey.FacialRecognitionState);
      expect(mocks.person.getLatestFaceDate).toHaveBeenCalledOnce();
      expect(mocks.person.getAllFaces).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.systemMetadata.set).not.toHaveBeenCalled();
      expect(mocks.person.vacuum).not.toHaveBeenCalled();
    });

    it('should delete existing people if forced', async () => {
      const face = AssetFaceFactory.from().person().build();
      const person = PersonFactory.create();

      mocks.job.getJobCounts.mockResolvedValue({
        active: 1,
        waiting: 0,
        paused: 0,
        completed: 0,
        failed: 0,
        delayed: 0,
      });
      mocks.person.getAll.mockReturnValue(makeStream([face.person!, person]));
      mocks.person.getAllFaces.mockReturnValue(makeStream([face]));
      mocks.person.getAllWithoutFaces.mockResolvedValue([person]);
      mocks.person.unassignFaces.mockResolvedValue();

      await sut.handleQueueRecognizeFaces({ force: true });

      expect(mocks.person.deleteFaces).not.toHaveBeenCalled();
      expect(mocks.person.unassignFaces).toHaveBeenCalledWith({ sourceType: SourceType.MachineLearning });
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        {
          name: JobName.FacialRecognition,
          data: { id: face.id, deferred: false },
        },
      ]);
      expect(mocks.person.delete).toHaveBeenCalledWith([person.id]);
      expect(mocks.storage.unlink).toHaveBeenCalledWith(person.thumbnailPath);
      expect(mocks.person.vacuum).toHaveBeenCalledWith({ reindexVectors: false });
    });
  });

  describe('handleDetectFaces', () => {
    it('should skip if machine learning is disabled', async () => {
      mocks.systemMetadata.get.mockResolvedValue(systemConfigStub.machineLearningDisabled);

      await expect(sut.handleDetectFaces({ id: 'foo' })).resolves.toBe(JobStatus.Skipped);
      expect(mocks.asset.getByIds).not.toHaveBeenCalled();
      expect(mocks.systemMetadata.get).toHaveBeenCalled();
    });

    it('should skip when no resize path', async () => {
      const asset = AssetFactory.from().exif().build();
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));
      await sut.handleDetectFaces({ id: asset.id });
      expect(mocks.machineLearning.detectFaces).not.toHaveBeenCalled();
    });

    it('should handle no results', async () => {
      const start = Date.now();
      const asset = AssetFactory.from().file({ type: AssetFileType.Preview }).exif().build();

      mocks.machineLearning.detectFaces.mockResolvedValue({ imageHeight: 500, imageWidth: 400, faces: [] });
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));
      await sut.handleDetectFaces({ id: asset.id });
      expect(mocks.machineLearning.detectFaces).toHaveBeenCalledWith(
        asset.files[0].path,
        expect.objectContaining({ minScore: 0.7, modelName: 'buffalo_l' }),
      );
      expect(mocks.job.queue).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();

      expect(mocks.asset.upsertJobStatus).toHaveBeenCalledWith({
        assetId: asset.id,
        facesRecognizedAt: expect.any(Date),
      });
      const facesRecognizedAt = mocks.asset.upsertJobStatus.mock.calls[0][0].facesRecognizedAt as Date;
      expect(facesRecognizedAt.getTime()).toBeGreaterThanOrEqual(start);
    });

    it('should create a face with no person and queue recognition job', async () => {
      const asset = AssetFactory.from().file({ type: AssetFileType.Preview }).exif().build();
      const face = AssetFaceFactory.create({ assetId: asset.id });
      mocks.crypto.randomUUID.mockReturnValue(face.id);
      mocks.machineLearning.detectFaces.mockResolvedValue(getAsDetectedFace(face));
      mocks.search.searchFaces.mockResolvedValue([{ ...face, distance: 0.7 }]);
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));
      mocks.person.refreshFaces.mockResolvedValue();

      await sut.handleDetectFaces({ id: asset.id });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.objectContaining({ id: face.id, assetId: asset.id })],
        [],
        [{ faceId: face.id, embedding: '[1, 2, 3, 4]' }],
      );
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        { name: JobName.FacialRecognitionQueueAll, data: { force: false } },
        { name: JobName.FacialRecognition, data: { id: face.id } },
      ]);
      expect(mocks.person.reassignFace).not.toHaveBeenCalled();
      expect(mocks.person.reassignFacesWithHistory).not.toHaveBeenCalled();
    });

    it('should process enabled videos by sampling frames', async () => {
      const asset = AssetFactory.from({ type: AssetType.Video }).exif().build();
      const face = AssetFaceFactory.create({ assetId: asset.id });

      mocks.systemMetadata.get.mockResolvedValue({
        machineLearning: {
          facialRecognition: {
            video: { enabled: true, intervalSeconds: 5, maxFramesPerVideo: 30, downscaleLongEdge: 1440 },
          },
        },
      });
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));
      mocks.media.probe.mockResolvedValue({
        format: { duration: 12, bitrate: 0, formatName: 'mov', formatLongName: 'QuickTime' },
        videoStreams: [
          {
            index: 0,
            width: 3840,
            height: 2160,
            codecName: 'h264',
            frameCount: 0,
            rotation: 0,
            isHDR: false,
            bitrate: 0,
            pixelFormat: 'yuv420p',
          },
        ],
        audioStreams: [],
      });
      mocks.storage.checkFileExists.mockResolvedValue(false);
      mocks.person.upsertFaceFrames.mockImplementation((frames) =>
        Promise.resolve(frames.map((frame, index) => ({ ...frame, id: `frame-${index}`, createdAt: new Date() }))),
      );
      mocks.machineLearning.detectFaces
        .mockResolvedValueOnce(getAsDetectedFace(face))
        .mockResolvedValue({ faces: [], imageHeight: 1080, imageWidth: 1440 });
      mocks.crypto.randomUUID.mockReturnValue(face.id);

      await sut.handleDetectFaces({ id: asset.id });

      expect(mocks.media.extractVideoFrame).toHaveBeenCalledTimes(3);
      expect(mocks.media.extractVideoFrame).toHaveBeenNthCalledWith(
        1,
        asset.originalPath,
        expect.stringContaining(`${asset.id}_face_frame_`),
        { timestampSeconds: 2.5, maxSize: 1440 },
      );
      expect(mocks.media.extractVideoFrame).toHaveBeenNthCalledWith(
        2,
        asset.originalPath,
        expect.stringContaining(`${asset.id}_face_frame_`),
        { timestampSeconds: 7.5, maxSize: 1440 },
      );
      expect(mocks.media.extractVideoFrame).toHaveBeenNthCalledWith(
        3,
        asset.originalPath,
        expect.stringContaining(`${asset.id}_face_frame_`),
        { timestampSeconds: 11, maxSize: 1440 },
      );
      expect(mocks.machineLearning.detectFaces).toHaveBeenCalledTimes(3);
      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.objectContaining({ id: face.id, assetId: asset.id, frameId: 'frame-0' })],
        [],
        [{ faceId: face.id, embedding: '[1, 2, 3, 4]' }],
      );
    });

    it('should delete an existing face not among the new detected faces', async () => {
      const asset = AssetFactory.from().face().file({ type: AssetFileType.Preview }).exif().build();
      mocks.machineLearning.detectFaces.mockResolvedValue({ faces: [], imageHeight: 500, imageWidth: 400 });
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));

      await sut.handleDetectFaces({ id: asset.id });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith([], [asset.faces[0].id], []);
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.person.reassignFace).not.toHaveBeenCalled();
      expect(mocks.person.reassignFacesWithHistory).not.toHaveBeenCalled();
    });

    it('should add new face and delete an existing face not among the new detected faces', async () => {
      const assetId = newUuid();
      const face = AssetFaceFactory.create({
        assetId,
        boundingBoxX1: 200,
        boundingBoxX2: 300,
        boundingBoxY1: 200,
        boundingBoxY2: 300,
      });
      const asset = AssetFactory.from({ id: assetId }).face().file({ type: AssetFileType.Preview }).exif().build();
      mocks.machineLearning.detectFaces.mockResolvedValue(getAsDetectedFace(face));
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));
      mocks.crypto.randomUUID.mockReturnValue(face.id);
      mocks.person.refreshFaces.mockResolvedValue();

      await sut.handleDetectFaces({ id: asset.id });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.objectContaining({ id: face.id, assetId: asset.id })],
        [asset.faces[0].id],
        [{ faceId: face.id, embedding: '[1, 2, 3, 4]' }],
      );
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        { name: JobName.FacialRecognitionQueueAll, data: { force: false } },
        { name: JobName.FacialRecognition, data: { id: face.id } },
      ]);
      expect(mocks.person.reassignFace).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
    });

    it('should add embedding to matching metadata face', async () => {
      const face = AssetFaceFactory.create({ sourceType: SourceType.Exif });
      const asset = AssetFactory.from().face(face).file({ type: AssetFileType.Preview }).exif().build();
      mocks.machineLearning.detectFaces.mockResolvedValue(getAsDetectedFace(face));
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));
      mocks.person.refreshFaces.mockResolvedValue();

      await sut.handleDetectFaces({ id: asset.id });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith([], [], [{ faceId: face.id, embedding: '[1, 2, 3, 4]' }]);
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.person.reassignFace).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
    });

    it('should not add embedding to non-matching metadata face', async () => {
      const assetId = newUuid();
      const face = AssetFaceFactory.create({ assetId, sourceType: SourceType.Exif });
      const asset = AssetFactory.from({ id: assetId }).file({ type: AssetFileType.Preview }).exif().build();
      mocks.machineLearning.detectFaces.mockResolvedValue(getAsDetectedFace(face));
      mocks.assetJob.getForDetectFacesJob.mockResolvedValue(getForDetectedFaces(asset));
      mocks.crypto.randomUUID.mockReturnValue(face.id);

      await sut.handleDetectFaces({ id: asset.id });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.objectContaining({ id: face.id, assetId: asset.id })],
        [],
        [{ faceId: face.id, embedding: '[1, 2, 3, 4]' }],
      );
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        { name: JobName.FacialRecognitionQueueAll, data: { force: false } },
        { name: JobName.FacialRecognition, data: { id: face.id } },
      ]);
      expect(mocks.person.reassignFace).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
    });
  });

  describe('handleRecognizeFaces', () => {
    it('should fail if face does not exist', async () => {
      expect(await sut.handleRecognizeFaces({ id: 'unknown-face' })).toBe(JobStatus.Failed);

      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
      expect(mocks.person.create).not.toHaveBeenCalled();
    });

    it('should fail if face does not have asset', async () => {
      const face = AssetFaceFactory.create();
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(face, null));

      expect(await sut.handleRecognizeFaces({ id: face.id })).toBe(JobStatus.Failed);

      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
      expect(mocks.person.create).not.toHaveBeenCalled();
    });

    it('should skip if face already has an assigned person', async () => {
      const asset = AssetFactory.create();
      const face = AssetFaceFactory.from({ assetId: asset.id }).person().build();
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(face, asset));

      expect(await sut.handleRecognizeFaces({ id: face.id })).toBe(JobStatus.Skipped);

      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
      expect(mocks.person.create).not.toHaveBeenCalled();
    });

    it('should match existing person', async () => {
      const asset = AssetFactory.create();

      const [noPerson1, noPerson2, primaryFace, face] = [
        AssetFaceFactory.create({ assetId: asset.id }),
        AssetFaceFactory.create(),
        AssetFaceFactory.from().person().build(),
        AssetFaceFactory.from().person().build(),
      ];

      const faces = [
        { ...noPerson1, distance: 0 },
        { ...primaryFace, distance: 0.2 },
        { ...noPerson2, distance: 0.3 },
        { ...face, distance: 0.4 },
      ] as FaceSearchResult[];

      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { minFaces: 1 } } });
      mocks.search.searchFaces.mockResolvedValue(faces);
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(noPerson1, asset));
      mocks.person.create.mockResolvedValue(primaryFace.person!);

      await sut.handleRecognizeFaces({ id: noPerson1.id });

      expect(mocks.person.create).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).toHaveBeenCalledTimes(1);
      expect(mocks.person.reassignFaces).toHaveBeenCalledWith({
        faceIds: expect.arrayContaining([noPerson1.id]),
        newPersonId: primaryFace.person!.id,
      });
      expect(mocks.person.reassignFaces).toHaveBeenCalledWith({
        faceIds: expect.not.arrayContaining([face.id]),
        newPersonId: primaryFace.person!.id,
      });
    });

    it('should match existing person if their birth date is unknown', async () => {
      const asset = AssetFactory.create();
      const [noPerson, face, faceWithBirthDate] = [
        AssetFaceFactory.create({ assetId: asset.id }),
        AssetFaceFactory.from().person().build(),
        AssetFaceFactory.from().person({ birthDate: newDate() }).build(),
      ];

      const faces = [
        { ...noPerson, distance: 0 },
        { ...face, distance: 0.2 },
        { ...faceWithBirthDate, distance: 0.3 },
      ] as FaceSearchResult[];

      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { minFaces: 1 } } });
      mocks.search.searchFaces.mockResolvedValue(faces);
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(noPerson, asset));
      mocks.person.create.mockResolvedValue(face.person!);

      await sut.handleRecognizeFaces({ id: noPerson.id });

      expect(mocks.person.create).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).toHaveBeenCalledTimes(1);
      expect(mocks.person.reassignFaces).toHaveBeenCalledWith({
        faceIds: expect.arrayContaining([noPerson.id]),
        newPersonId: face.person!.id,
      });
      expect(mocks.person.reassignFaces).toHaveBeenCalledWith({
        faceIds: expect.not.arrayContaining([face.id]),
        newPersonId: face.person!.id,
      });
    });

    it('should match existing person if their birth date is before file creation', async () => {
      const asset = AssetFactory.create();
      const [noPerson, face, faceWithBirthDate] = [
        AssetFaceFactory.create({ assetId: asset.id }),
        AssetFaceFactory.from().person().build(),
        AssetFaceFactory.from().person({ birthDate: newDate() }).build(),
      ];

      const faces = [
        { ...noPerson, distance: 0 },
        { ...faceWithBirthDate, distance: 0.2 },
        { ...face, distance: 0.3 },
      ] as FaceSearchResult[];

      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { minFaces: 1 } } });
      mocks.search.searchFaces.mockResolvedValue(faces);
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(noPerson, asset));
      mocks.person.create.mockResolvedValue(face.person!);

      await sut.handleRecognizeFaces({ id: noPerson.id });

      expect(mocks.person.create).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).toHaveBeenCalledTimes(1);
      expect(mocks.person.reassignFaces).toHaveBeenCalledWith({
        faceIds: expect.arrayContaining([noPerson.id]),
        newPersonId: faceWithBirthDate.person!.id,
      });
      expect(mocks.person.reassignFaces).toHaveBeenCalledWith({
        faceIds: expect.not.arrayContaining([face.id]),
        newPersonId: faceWithBirthDate.person!.id,
      });
    });

    it('should create a new person if the face is a core point with no person', async () => {
      const asset = AssetFactory.create();
      const [noPerson1, noPerson2] = [AssetFaceFactory.create({ assetId: asset.id }), AssetFaceFactory.create()];
      const person = PersonFactory.create();

      const faces = [
        { ...noPerson1, distance: 0 },
        { ...noPerson2, distance: 0.3 },
      ] as FaceSearchResult[];

      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { minFaces: 1 } } });
      mocks.search.searchFaces.mockResolvedValue(faces);
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(noPerson1, asset));
      mocks.person.create.mockResolvedValue(person);

      await sut.handleRecognizeFaces({ id: noPerson1.id });

      expect(mocks.person.create).toHaveBeenCalledWith({
        ownerId: asset.ownerId,
        faceAssetId: noPerson1.id,
      });
      expect(mocks.person.reassignFaces).toHaveBeenCalledWith({
        faceIds: [noPerson1.id],
        newPersonId: person.id,
      });
    });

    it('should not queue face with no matches', async () => {
      const asset = AssetFactory.create();
      const face = AssetFaceFactory.create({ assetId: asset.id });
      const faces = [{ ...face, distance: 0 }] as FaceSearchResult[];

      mocks.search.searchFaces.mockResolvedValue(faces);
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(face, asset));
      mocks.person.create.mockResolvedValue(PersonFactory.create());

      await sut.handleRecognizeFaces({ id: face.id });

      expect(mocks.job.queue).not.toHaveBeenCalled();
      expect(mocks.search.searchFaces).toHaveBeenCalledTimes(1);
      expect(mocks.person.create).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
    });

    it('should defer non-core faces to end of queue', async () => {
      const asset = AssetFactory.create();
      const [noPerson1, noPerson2] = [AssetFaceFactory.create({ assetId: asset.id }), AssetFaceFactory.create()];

      const faces = [
        { ...noPerson1, distance: 0 },
        { ...noPerson2, distance: 0.4 },
      ] as FaceSearchResult[];

      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { minFaces: 3 } } });
      mocks.search.searchFaces.mockResolvedValue(faces);
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(noPerson1, asset));
      mocks.person.create.mockResolvedValue(PersonFactory.create());

      await sut.handleRecognizeFaces({ id: noPerson1.id });

      expect(mocks.job.queue).toHaveBeenCalledWith({
        name: JobName.FacialRecognition,
        data: { id: noPerson1.id, deferred: true },
      });
      expect(mocks.search.searchFaces).toHaveBeenCalledTimes(1);
      expect(mocks.person.create).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
    });

    it('should not assign person to deferred non-core face with no matching person', async () => {
      const asset = AssetFactory.create();
      const [noPerson1, noPerson2] = [AssetFaceFactory.create({ assetId: asset.id }), AssetFaceFactory.create()];

      const faces = [
        { ...noPerson1, distance: 0 },
        { ...noPerson2, distance: 0.4 },
      ] as FaceSearchResult[];

      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { minFaces: 3 } } });
      mocks.search.searchFaces.mockResolvedValueOnce(faces).mockResolvedValueOnce([]);
      mocks.person.getFaceForFacialRecognitionJob.mockResolvedValue(getForFacialRecognitionJob(noPerson1, asset));
      mocks.person.create.mockResolvedValue(PersonFactory.create());

      await sut.handleRecognizeFaces({ id: noPerson1.id, deferred: true });

      expect(mocks.job.queue).not.toHaveBeenCalled();
      expect(mocks.search.searchFaces).toHaveBeenCalledTimes(2);
      expect(mocks.person.create).not.toHaveBeenCalled();
      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();
    });
  });

  describe('mergePerson', () => {
    it('should require person.write and person.merge permission', async () => {
      const auth = AuthFactory.create();
      const [person, mergePerson] = [PersonFactory.create(), PersonFactory.create()];

      mocks.person.getById.mockResolvedValueOnce(person);
      mocks.person.getById.mockResolvedValueOnce(mergePerson);

      await expect(sut.mergePerson(auth, person.id, { ids: [mergePerson.id] })).rejects.toBeInstanceOf(
        BadRequestException,
      );

      expect(mocks.person.reassignFaces).not.toHaveBeenCalled();

      expect(mocks.person.delete).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should merge two people without smart merge', async () => {
      const auth = AuthFactory.create();
      const [person, mergePerson] = [PersonFactory.create(), PersonFactory.create()];
      const batchId = newUuid();

      mocks.person.getById.mockResolvedValueOnce(person);
      mocks.person.getById.mockResolvedValueOnce(mergePerson);
      mocks.crypto.randomUUID.mockReturnValue(batchId);
      mocks.person.reassignFacesWithHistory.mockResolvedValue([]);
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set([person.id]));
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set([mergePerson.id]));

      await expect(sut.mergePerson(auth, person.id, { ids: [mergePerson.id] })).resolves.toEqual([
        { id: mergePerson.id, success: true },
      ]);

      expect(mocks.person.reassignFacesWithHistory).toHaveBeenCalledWith({
        newPersonId: person.id,
        oldPersonId: mergePerson.id,
        ownerId: auth.user.id,
        actorId: auth.user.id,
        source: FaceAssignmentHistorySource.Merge,
        batchId,
      });

      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should merge two people with smart merge', async () => {
      const auth = AuthFactory.create();
      const [person, mergePerson] = [
        PersonFactory.create({ name: undefined }),
        PersonFactory.create({ name: 'Merge person' }),
      ];
      const batchId = newUuid();

      mocks.person.getById.mockResolvedValueOnce(person);
      mocks.person.getById.mockResolvedValueOnce(mergePerson);
      mocks.person.update.mockResolvedValue({ ...person, name: mergePerson.name });
      mocks.crypto.randomUUID.mockReturnValue(batchId);
      mocks.person.reassignFacesWithHistory.mockResolvedValue([]);
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set([person.id]));
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set([mergePerson.id]));

      await expect(sut.mergePerson(auth, person.id, { ids: [mergePerson.id] })).resolves.toEqual([
        { id: mergePerson.id, success: true },
      ]);

      expect(mocks.person.reassignFacesWithHistory).toHaveBeenCalledWith({
        newPersonId: person.id,
        oldPersonId: mergePerson.id,
        ownerId: auth.user.id,
        actorId: auth.user.id,
        source: FaceAssignmentHistorySource.Merge,
        batchId,
      });

      expect(mocks.person.update).toHaveBeenCalledWith({
        id: person.id,
        name: mergePerson.name,
      });

      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should throw an error when the primary person is not found', async () => {
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set(['person-1']));

      await expect(sut.mergePerson(authStub.admin, 'person-1', { ids: ['person-2'] })).rejects.toBeInstanceOf(
        BadRequestException,
      );

      expect(mocks.person.delete).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(authStub.admin.user.id, new Set(['person-1']));
    });

    it('should handle invalid merge ids', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValueOnce(person);
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set([person.id]));
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set(['unknown']));

      await expect(sut.mergePerson(auth, person.id, { ids: ['unknown'] })).resolves.toEqual([
        { id: 'unknown', success: false, error: BulkIdErrorReason.NOT_FOUND },
      ]);

      expect(mocks.person.reassignFacesWithHistory).not.toHaveBeenCalled();
      expect(mocks.person.delete).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should handle an error reassigning faces', async () => {
      const auth = AuthFactory.create();
      const [person, mergePerson] = [PersonFactory.create(), PersonFactory.create()];

      mocks.person.getById.mockResolvedValueOnce(person);
      mocks.person.getById.mockResolvedValueOnce(mergePerson);
      mocks.person.reassignFacesWithHistory.mockRejectedValue(new Error('update failed'));
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set([person.id]));
      mocks.access.person.checkOwnerAccess.mockResolvedValueOnce(new Set([mergePerson.id]));

      await expect(sut.mergePerson(auth, person.id, { ids: [mergePerson.id] })).resolves.toEqual([
        { id: mergePerson.id, success: false, error: BulkIdErrorReason.UNKNOWN },
      ]);

      expect(mocks.person.delete).not.toHaveBeenCalled();
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });
  });

  describe('getStatistics', () => {
    it('should get correct number of person', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValue(person);
      mocks.person.getStatistics.mockResolvedValue({ assets: 3 });
      mocks.access.person.checkOwnerAccess.mockResolvedValue(new Set([person.id]));
      await expect(sut.getStatistics(auth, person.id)).resolves.toEqual({ assets: 3 });
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });

    it('should require person.read permission', async () => {
      const auth = AuthFactory.create();
      const person = PersonFactory.create();

      mocks.person.getById.mockResolvedValue(person);
      await expect(sut.getStatistics(auth, person.id)).rejects.toBeInstanceOf(BadRequestException);
      expect(mocks.access.person.checkOwnerAccess).toHaveBeenCalledWith(auth.user.id, new Set([person.id]));
    });
  });

  describe('mapFace', () => {
    it('should map a face', () => {
      const user = UserFactory.create();
      const auth = AuthFactory.create({ id: user.id });
      const person = PersonFactory.create({ ownerId: user.id });
      const face = AssetFaceFactory.from().person(person).build();

      expect(mapFaces(getForAssetFace(face), auth)).toEqual({
        boundingBoxX1: 100,
        boundingBoxX2: 200,
        boundingBoxY1: 100,
        boundingBoxY2: 200,
        assetId: face.assetId,
        id: face.id,
        imageHeight: 500,
        imageWidth: 400,
        sourceType: SourceType.MachineLearning,
        person: mapPerson(person),
      });
    });

    it('should not map person if person is null', () => {
      expect(mapFaces(getForAssetFace(AssetFaceFactory.create()), AuthFactory.create()).person).toBeNull();
    });

    it('should not map person if person does not match auth user id', () => {
      expect(
        mapFaces(getForAssetFace(AssetFaceFactory.from().person().build()), AuthFactory.create()).person,
      ).toBeNull();
    });
  });
});
