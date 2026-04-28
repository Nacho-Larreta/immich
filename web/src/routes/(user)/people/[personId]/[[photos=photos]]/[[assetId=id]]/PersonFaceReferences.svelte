<script lang="ts">
  import ImageThumbnail from '$lib/components/assets/thumbnail/ImageThumbnail.svelte';
  import PeoplePickerModal from '$lib/modals/PeoplePickerModal.svelte';
  import { Route } from '$lib/route';
  import { getFaceSourceImageUrl, getPeopleThumbnailUrl } from '$lib/utils';
  import { handleError } from '$lib/utils/handle-error';
  import {
    FaceAssignmentHistorySource,
    FaceSuggestionFeedbackDecision,
    getPerson,
    getPersonFaceAssignmentHistory,
    getPersonFaces,
    getPersonFaceSuggestions,
    reassignFacesById,
    respondToPersonFaceSuggestion,
    revertPersonFaceAssignmentHistory,
    updatePerson,
    type AssetFaceResponseDto,
    type PersonFaceAssignmentHistoryResponseDto,
    type PersonFaceSuggestionResponseDto,
    type PersonResponseDto,
  } from '@immich/sdk';
  import { Button, LoadingSpinner, modalManager, toastManager } from '@immich/ui';
  import { mdiHistory, mdiImageCheckOutline, mdiOpenInNew, mdiSwapHorizontal } from '@mdi/js';
  import { DateTime } from 'luxon';
  import { onMount } from 'svelte';
  import { locale, t } from 'svelte-i18n';

  interface Props {
    person: PersonResponseDto;
    onPersonUpdate: (person: PersonResponseDto) => void;
  }

  let { person, onPersonUpdate }: Props = $props();

  const pageSize = 48;
  const historyPageSize = 10;
  const suggestionPageSize = 12;
  const facePreviewCache: Record<string, Promise<string | null> | undefined> = {};

  type FacePreviewSource = Pick<
    AssetFaceResponseDto,
    'id' | 'imageWidth' | 'imageHeight' | 'boundingBoxX1' | 'boundingBoxX2' | 'boundingBoxY1' | 'boundingBoxY2'
  >;

  let faces: AssetFaceResponseDto[] = $state([]);
  let history: PersonFaceAssignmentHistoryResponseDto[] = $state([]);
  let suggestions: PersonFaceSuggestionResponseDto[] = $state([]);
  let page = $state(1);
  let suggestionPage = $state(1);
  let hasNextPage = $state(false);
  let hasNextSuggestionPage = $state(false);
  let isLoading = $state(true);
  let isLoadingHistory = $state(true);
  let isLoadingSuggestions = $state(true);
  let isLoadingMore = $state(false);
  let isLoadingMoreSuggestions = $state(false);
  let updatingFaceId = $state<string | null>(null);
  let reassigningFaceId = $state<string | null>(null);
  let revertingHistoryId = $state<string | null>(null);
  let respondingSuggestionFaceId = $state<string | null>(null);
  let featureThumbnailUrlOverride = $state<string | null>(null);

  const isUpdating = $derived(
    !!updatingFaceId || !!reassigningFaceId || !!revertingHistoryId || !!respondingSuggestionFaceId,
  );
  const featureThumbnailUrl = $derived(featureThumbnailUrlOverride ?? getPeopleThumbnailUrl(person));

  const loadFacePreview = async (face: FacePreviewSource) => {
    const image = new Image();
    image.src = getFaceSourceImageUrl(face.id);

    await new Promise<void>((resolve) => {
      image.addEventListener('load', () => resolve(), { once: true });
      image.addEventListener('error', () => resolve(), { once: true });
    });

    if (!image.naturalWidth || !image.naturalHeight || !face.imageWidth || !face.imageHeight) {
      return null;
    }

    const x1 = Math.max(0, Math.min(image.naturalWidth, (image.naturalWidth / face.imageWidth) * face.boundingBoxX1));
    const x2 = Math.max(0, Math.min(image.naturalWidth, (image.naturalWidth / face.imageWidth) * face.boundingBoxX2));
    const y1 = Math.max(
      0,
      Math.min(image.naturalHeight, (image.naturalHeight / face.imageHeight) * face.boundingBoxY1),
    );
    const y2 = Math.max(
      0,
      Math.min(image.naturalHeight, (image.naturalHeight / face.imageHeight) * face.boundingBoxY2),
    );
    const width = x2 - x1;
    const height = y2 - y1;

    if (width <= 0 || height <= 0) {
      return null;
    }

    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;

    const context = canvas.getContext('2d');
    if (!context) {
      return null;
    }

    context.drawImage(image, x1, y1, width, height, 0, 0, width, height);
    return canvas.toDataURL('image/jpeg', 0.85);
  };

  const getFacePreview = (face: FacePreviewSource) => {
    const cached = facePreviewCache[face.id];
    if (cached) {
      return cached;
    }

    const preview = loadFacePreview(face);
    facePreviewCache[face.id] = preview;
    return preview;
  };

  const loadFaces = async ({ reset = false } = {}) => {
    if (reset) {
      isLoading = true;
      page = 1;
    } else {
      isLoadingMore = true;
    }

    try {
      const nextPage = reset ? 1 : page;
      const response = await getPersonFaces({ id: person.id, page: nextPage, size: pageSize });

      faces = reset ? response.faces : [...faces, ...response.faces];
      hasNextPage = response.hasNextPage;
      page = nextPage + 1;
    } catch (error) {
      handleError(error, $t('errors.failed_to_load_people'));
    } finally {
      isLoading = false;
      isLoadingMore = false;
    }
  };

  const loadHistory = async () => {
    isLoadingHistory = true;

    try {
      const response = await getPersonFaceAssignmentHistory({ id: person.id, page: 1, size: historyPageSize });
      history = response.history;
    } catch (error) {
      handleError(error, $t('errors.unable_to_load_face_assignment_history'));
    } finally {
      isLoadingHistory = false;
    }
  };

  const loadSuggestions = async ({ reset = false } = {}) => {
    if (reset) {
      isLoadingSuggestions = true;
      suggestionPage = 1;
    } else {
      isLoadingMoreSuggestions = true;
    }

    try {
      const nextPage = reset ? 1 : suggestionPage;
      const response = await getPersonFaceSuggestions({ id: person.id, page: nextPage, size: suggestionPageSize });
      suggestions = reset ? response.suggestions : [...suggestions, ...response.suggestions];
      hasNextSuggestionPage = response.hasNextPage;
      suggestionPage = nextPage + 1;
    } catch (error) {
      handleError(error, $t('errors.unable_to_load_face_suggestions'));
    } finally {
      isLoadingSuggestions = false;
      isLoadingMoreSuggestions = false;
    }
  };

  const formatHistoryDate = (date: string) =>
    DateTime.fromISO(date, { locale: $locale ?? undefined }).toLocaleString(DateTime.DATETIME_MED);

  const getHistorySourceLabel = (source: FaceAssignmentHistorySource) => {
    switch (source) {
      case FaceAssignmentHistorySource.ManualReassign: {
        return $t('face_assignment_history_source_manual');
      }
      case FaceAssignmentHistorySource.ManualBulkReassign: {
        return $t('face_assignment_history_source_bulk');
      }
      case FaceAssignmentHistorySource.Merge: {
        return $t('face_assignment_history_source_merge');
      }
      case FaceAssignmentHistorySource.SuggestionAccepted: {
        return $t('face_assignment_history_source_suggestion');
      }
    }
  };

  const getHistoryActionLabel = (entry: PersonFaceAssignmentHistoryResponseDto) =>
    entry.newPersonId === person.id
      ? $t('face_assignment_history_assigned_to_person')
      : $t('face_assignment_history_moved_from_person');

  const handleSetFeaturePhoto = async (face: AssetFaceResponseDto) => {
    if (updatingFaceId) {
      return;
    }

    updatingFaceId = face.id;
    try {
      const [updatedPerson, preview] = await Promise.all([
        updatePerson({
          id: person.id,
          personUpdateDto: { featureFaceId: face.id },
        }),
        getFacePreview(face),
      ]);

      featureThumbnailUrlOverride = preview ?? getPeopleThumbnailUrl(updatedPerson, Date.now().toString());
      onPersonUpdate(updatedPerson);
      toastManager.primary($t('feature_photo_updated'));
    } catch (error) {
      handleError(error, $t('errors.unable_to_set_feature_photo'));
    } finally {
      updatingFaceId = null;
    }
  };

  const handleReassignFace = async (face: AssetFaceResponseDto) => {
    if (isUpdating) {
      return;
    }

    const selectedPeople = await modalManager.show(PeoplePickerModal, { excludedIds: [person.id] });
    const selectedPerson = selectedPeople?.[0];
    if (!selectedPerson) {
      return;
    }

    reassigningFaceId = face.id;
    try {
      await reassignFacesById({
        id: selectedPerson.id,
        faceDto: { id: face.id },
      });

      faces = faces.filter(({ id }) => id !== face.id);
      featureThumbnailUrlOverride = null;

      const refreshedPerson = await getPerson({ id: person.id });
      onPersonUpdate(refreshedPerson);
      await loadHistory();

      toastManager.primary(
        $t('face_reference_reassigned', {
          values: { name: selectedPerson.name || $t('add_a_name') },
        }),
      );
    } catch (error) {
      handleError(error, $t('errors.unable_to_reassign_face_reference'));
    } finally {
      reassigningFaceId = null;
    }
  };

  const handleRevertHistory = async (entry: PersonFaceAssignmentHistoryResponseDto) => {
    if (isUpdating || entry.revertedAt) {
      return;
    }

    const confirmed = await modalManager.showDialog({
      prompt: $t('face_assignment_history_revert_confirmation'),
      confirmText: $t('undo'),
    });
    if (!confirmed) {
      return;
    }

    revertingHistoryId = entry.id;
    try {
      await revertPersonFaceAssignmentHistory({ id: person.id, historyId: entry.id });

      featureThumbnailUrlOverride = null;
      await Promise.all([loadFaces({ reset: true }), loadHistory()]);

      const refreshedPerson = await getPerson({ id: person.id });
      onPersonUpdate(refreshedPerson);
      toastManager.primary($t('face_assignment_history_revert_success'));
    } catch (error) {
      handleError(error, $t('errors.unable_to_revert_face_assignment_history'));
    } finally {
      revertingHistoryId = null;
    }
  };

  const handleSuggestionFeedback = async (
    suggestion: PersonFaceSuggestionResponseDto,
    decision: FaceSuggestionFeedbackDecision,
  ) => {
    if (isUpdating) {
      return;
    }

    respondingSuggestionFaceId = suggestion.id;
    try {
      await respondToPersonFaceSuggestion({
        id: person.id,
        faceId: suggestion.id,
        personFaceSuggestionFeedbackDto: { decision },
      });

      suggestions = suggestions.filter(({ id }) => id !== suggestion.id);

      if (decision === FaceSuggestionFeedbackDecision.Accepted) {
        featureThumbnailUrlOverride = null;
        await Promise.all([loadFaces({ reset: true }), loadHistory(), loadSuggestions({ reset: true })]);

        const refreshedPerson = await getPerson({ id: person.id });
        onPersonUpdate(refreshedPerson);
        toastManager.primary($t('face_suggestion_accepted'));
      } else {
        toastManager.primary($t('face_suggestion_rejected'));
      }
    } catch (error) {
      handleError(error, $t('errors.unable_to_update_face_suggestion'));
    } finally {
      respondingSuggestionFaceId = null;
    }
  };

  const handleSkipSuggestion = (suggestion: PersonFaceSuggestionResponseDto) => {
    suggestions = suggestions.filter(({ id }) => id !== suggestion.id);
  };

  onMount(() => {
    void Promise.all([loadFaces({ reset: true }), loadHistory(), loadSuggestions({ reset: true })]);
  });
</script>

<section class="h-full overflow-y-auto px-4 py-12 text-primary sm:px-6 lg:px-10">
  <div class="mb-8 max-w-3xl">
    <div class="flex items-center gap-4">
      {#key featureThumbnailUrl}
        <ImageThumbnail
          circle
          shadow
          url={featureThumbnailUrl}
          altText={person.name}
          widthStyle="4rem"
          heightStyle="4rem"
        />
      {/key}

      <div>
        <h1 class="text-2xl font-semibold">{person.name || $t('add_a_name')}</h1>
        <p class="mt-1 text-sm text-gray-600 dark:text-gray-300">{$t('face_references_description')}</p>
      </div>
    </div>
  </div>

  {#if isLoading}
    <div class="flex h-56 items-center justify-center">
      <LoadingSpinner />
    </div>
  {:else}
    <div
      class="mb-8 rounded-3xl border border-immich-primary/20 bg-immich-primary/5 p-4 dark:border-immich-dark-primary/30 dark:bg-immich-dark-primary/20"
    >
      <div class="mb-3 flex items-start justify-between gap-4">
        <div>
          <h2 class="text-base font-semibold">{$t('face_suggestions')}</h2>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-300">
            {$t('face_suggestions_description', { values: { name: person.name || $t('person') } })}
          </p>
        </div>
      </div>

      {#if isLoadingSuggestions}
        <div class="flex h-28 items-center justify-center">
          <LoadingSpinner />
        </div>
      {:else if suggestions.length === 0}
        <p
          class="rounded-2xl border border-dashed border-immich-primary/30 p-4 text-sm text-gray-500 dark:border-immich-dark-primary/40 dark:text-gray-400"
        >
          {$t('face_suggestions_empty')}
        </p>
      {:else}
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
          {#each suggestions as suggestion (suggestion.id)}
            <article
              class="overflow-hidden rounded-2xl border border-gray-200 bg-white shadow-sm dark:border-gray-800 dark:bg-black/20"
            >
              <div class="grid grid-cols-[6rem_1fr] gap-3 p-3">
                <div class="relative aspect-square overflow-hidden rounded-xl bg-gray-100 dark:bg-immich-dark-gray">
                  {#await getFacePreview(suggestion)}
                    <div class="flex h-full w-full items-center justify-center">
                      <LoadingSpinner />
                    </div>
                  {:then preview}
                    <img
                      src={preview ?? '/src/lib/assets/no-thumbnail.png'}
                      alt={$t('face_suggestion_preview_alt', { values: { name: person.name || $t('person') } })}
                      class="h-full w-full object-cover"
                      draggable="false"
                    />
                  {/await}
                </div>

                <div class="flex min-w-0 flex-col justify-between gap-3">
                  <div>
                    <p class="font-semibold">
                      {$t('face_suggestion_question', { values: { name: person.name || $t('person') } })}
                    </p>
                    <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                      {$t('face_suggestion_distance', { values: { distance: suggestion.distance.toFixed(3) } })}
                    </p>
                  </div>

                  <div class="grid grid-cols-3 gap-2">
                    <Button
                      size="small"
                      leadingIcon={mdiImageCheckOutline}
                      loading={respondingSuggestionFaceId === suggestion.id}
                      disabled={isUpdating}
                      onclick={() => handleSuggestionFeedback(suggestion, FaceSuggestionFeedbackDecision.Accepted)}
                    >
                      {$t('yes')}
                    </Button>

                    <Button
                      size="small"
                      color="secondary"
                      variant="outline"
                      loading={respondingSuggestionFaceId === suggestion.id}
                      disabled={isUpdating}
                      onclick={() => handleSuggestionFeedback(suggestion, FaceSuggestionFeedbackDecision.Rejected)}
                    >
                      {$t('no')}
                    </Button>

                    <Button
                      size="small"
                      color="secondary"
                      variant="ghost"
                      disabled={isUpdating}
                      onclick={() => handleSkipSuggestion(suggestion)}
                    >
                      {$t('skip')}
                    </Button>
                  </div>
                </div>
              </div>
            </article>
          {/each}
        </div>

        {#if hasNextSuggestionPage}
          <div class="mt-4 flex justify-center">
            <Button
              size="small"
              color="secondary"
              variant="outline"
              loading={isLoadingMoreSuggestions}
              disabled={isLoadingMoreSuggestions}
              onclick={() => loadSuggestions()}
            >
              {$t('load_more_face_suggestions')}
            </Button>
          </div>
        {/if}
      {/if}
    </div>

    <div
      class="mb-8 rounded-3xl border border-gray-200 bg-gray-50/80 p-4 dark:border-gray-800 dark:bg-immich-dark-gray/50"
    >
      <div class="mb-3 flex items-start justify-between gap-4">
        <div>
          <h2 class="text-base font-semibold">{$t('face_assignment_history')}</h2>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-300">{$t('face_assignment_history_description')}</p>
        </div>
      </div>

      {#if isLoadingHistory}
        <div class="flex h-20 items-center justify-center">
          <LoadingSpinner />
        </div>
      {:else if history.length === 0}
        <p
          class="rounded-2xl border border-dashed border-gray-300 p-4 text-sm text-gray-500 dark:border-gray-700 dark:text-gray-400"
        >
          {$t('face_assignment_history_empty')}
        </p>
      {:else}
        <ul class="space-y-2">
          {#each history as entry (entry.id)}
            <li
              class="flex flex-col gap-3 rounded-2xl border border-gray-200 bg-white p-3 dark:border-gray-800 dark:bg-black/20 sm:flex-row sm:items-center sm:justify-between"
            >
              <div>
                <p class="font-medium">{getHistoryActionLabel(entry)}</p>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                  {getHistorySourceLabel(entry.source)} · {formatHistoryDate(entry.createdAt)}
                </p>
              </div>

              {#if entry.revertedAt}
                <span
                  class="rounded-full bg-gray-200 px-3 py-1 text-xs font-semibold text-gray-700 dark:bg-gray-700 dark:text-gray-200"
                >
                  {$t('face_assignment_history_reverted')}
                </span>
              {:else}
                <Button
                  size="small"
                  color="secondary"
                  variant="outline"
                  leadingIcon={mdiHistory}
                  loading={revertingHistoryId === entry.id}
                  disabled={isUpdating}
                  onclick={() => handleRevertHistory(entry)}
                >
                  {$t('undo')}
                </Button>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    </div>

    {#if faces.length === 0}
      <div
        class="flex min-h-56 items-center justify-center rounded-3xl border border-dashed border-gray-300 text-gray-500 dark:border-gray-700 dark:text-gray-400"
      >
        {$t('no_face_references')}
      </div>
    {:else}
      <div class="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 xl:grid-cols-6 2xl:grid-cols-8">
        {#each faces as face (face.id)}
          <article
            class="overflow-hidden rounded-2xl border border-gray-200 bg-white shadow-sm dark:border-gray-800 dark:bg-immich-dark-gray"
          >
            <div class="relative aspect-square bg-gray-100 dark:bg-immich-dark-primary/20">
              {#await getFacePreview(face)}
                <div class="flex h-full w-full items-center justify-center">
                  <LoadingSpinner />
                </div>
              {:then preview}
                <img
                  src={preview ?? '/src/lib/assets/no-thumbnail.png'}
                  alt={person.name || $t('person')}
                  class="h-full w-full object-cover"
                  draggable="false"
                />
              {/await}
            </div>

            <div class="space-y-2 p-3">
              <Button
                fullWidth
                size="small"
                leadingIcon={mdiImageCheckOutline}
                loading={updatingFaceId === face.id}
                disabled={isUpdating}
                onclick={() => handleSetFeaturePhoto(face)}
              >
                {$t('set_as_featured_photo')}
              </Button>

              <Button
                fullWidth
                size="small"
                color="secondary"
                variant="outline"
                leadingIcon={mdiSwapHorizontal}
                loading={reassigningFaceId === face.id}
                disabled={isUpdating}
                onclick={() => handleReassignFace(face)}
              >
                {$t('change_person')}
              </Button>

              <Button
                fullWidth
                size="small"
                color="secondary"
                variant="ghost"
                href={Route.viewAsset({ id: face.assetId })}
                leadingIcon={mdiOpenInNew}
              >
                {$t('view')}
              </Button>
            </div>
          </article>
        {/each}
      </div>

      {#if hasNextPage}
        <div class="mt-8 flex justify-center">
          <Button
            size="small"
            color="secondary"
            variant="outline"
            loading={isLoadingMore}
            disabled={isLoadingMore}
            onclick={() => loadFaces()}
          >
            {$t('load_more_face_references')}
          </Button>
        </div>
      {/if}
    {/if}
  {/if}
</section>
