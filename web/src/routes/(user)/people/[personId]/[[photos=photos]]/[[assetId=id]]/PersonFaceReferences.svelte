<script lang="ts">
  import noThumbnailUrl from '$lib/assets/no-thumbnail.png';
  import ImageThumbnail from '$lib/components/assets/thumbnail/ImageThumbnail.svelte';
  import PeoplePickerModal from '$lib/modals/PeoplePickerModal.svelte';
  import { Route } from '$lib/route';
  import { getFaceSourceImageUrl, getPeopleThumbnailUrl } from '$lib/utils';
  import { handleError } from '$lib/utils/handle-error';
  import { formatFaceSuggestionMatchScore } from '$lib/utils/people-utils';
  import {
    AssetJobName,
    FaceAssignmentHistorySource,
    FaceSuggestionFeedbackDecision,
    getPerson,
    getPersonFaceAssignmentHistory,
    getPersonFaces,
    getPersonFaceSuggestions,
    reassignFacesById,
    respondToPersonFaceSuggestions,
    revertPersonFaceAssignmentHistory,
    runAssetJobs,
    updatePerson,
    type AssetFaceResponseDto,
    type PersonFaceAssignmentHistoryResponseDto,
    type PersonFaceSuggestionResponseDto,
    type PersonResponseDto,
  } from '@immich/sdk';
  import { Button, LoadingSpinner, modalManager, toastManager } from '@immich/ui';
  import { mdiHistory, mdiImageCheckOutline, mdiImageRefreshOutline, mdiOpenInNew, mdiSwapHorizontal } from '@mdi/js';
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
  let pendingSuggestionIds = $state<string[]>([]);
  let selectedSuggestionIds = $state<string[]>([]);
  let brokenPreviewFaceIds = $state<string[]>([]);
  let regeneratingThumbnailAssetIds = $state<string[]>([]);
  let featureThumbnailUrlOverride = $state<string | null>(null);
  let isReviewMode = $state(false);

  const isRegeneratingThumbnails = $derived(regeneratingThumbnailAssetIds.length > 0);
  const isUpdating = $derived(
    !!updatingFaceId || !!reassigningFaceId || !!revertingHistoryId || isRegeneratingThumbnails,
  );
  const featureThumbnailUrl = $derived(featureThumbnailUrlOverride ?? getPeopleThumbnailUrl(person));
  const activeSuggestion = $derived(suggestions[0] ?? null);
  const referencesRoute = $derived(Route.viewPerson(person, { action: 'references' }));
  const selectedSuggestions = $derived(suggestions.filter(({ id }) => selectedSuggestionIds.includes(id)));
  const allVisibleSuggestionsSelected = $derived(
    suggestions.length > 0 && selectedSuggestions.length === suggestions.length,
  );
  const brokenVisibleFaceCount = $derived(
    [...faces, ...suggestions].filter(({ id }) => brokenPreviewFaceIds.includes(id)).length,
  );

  const setFacePreviewBroken = (faceId: string, broken: boolean) => {
    if (broken && !brokenPreviewFaceIds.includes(faceId)) {
      brokenPreviewFaceIds = [...brokenPreviewFaceIds, faceId];
      return;
    }

    if (!broken && brokenPreviewFaceIds.includes(faceId)) {
      brokenPreviewFaceIds = brokenPreviewFaceIds.filter((id) => id !== faceId);
    }
  };

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

    const preview = loadFacePreview(face).then((preview) => {
      setFacePreviewBroken(face.id, preview === null);
      return preview;
    });
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
      selectedSuggestionIds = selectedSuggestionIds.filter((id) =>
        suggestions.some((suggestion) => suggestion.id === id),
      );
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

  const getUniqueAssetIds = (items: Array<Pick<AssetFaceResponseDto, 'assetId'>>) => [
    ...new Set(items.map(({ assetId }) => assetId)),
  ];

  const getBrokenVisibleFaces = () => [...faces, ...suggestions].filter(({ id }) => brokenPreviewFaceIds.includes(id));

  const isSuggestionPending = (suggestion: PersonFaceSuggestionResponseDto) =>
    pendingSuggestionIds.includes(suggestion.id);

  const getSameAssetSuggestionCount = (suggestion: PersonFaceSuggestionResponseDto) =>
    suggestions.filter(({ assetId }) => assetId === suggestion.assetId).length;

  const toggleSuggestionSelection = (suggestion: PersonFaceSuggestionResponseDto) => {
    selectedSuggestionIds = selectedSuggestionIds.includes(suggestion.id)
      ? selectedSuggestionIds.filter((id) => id !== suggestion.id)
      : [...selectedSuggestionIds, suggestion.id];
  };

  const toggleAllVisibleSuggestions = () => {
    selectedSuggestionIds = allVisibleSuggestionsSelected ? [] : suggestions.map(({ id }) => id);
  };

  const selectSuggestionsByAsset = (assetId: string) => {
    const sameAssetSuggestionIds = suggestions
      .filter((suggestion) => suggestion.assetId === assetId)
      .map(({ id }) => id);

    selectedSuggestionIds = [...new Set([...selectedSuggestionIds, ...sameAssetSuggestionIds])];
  };

  const refreshPersonInBackground = () => {
    void getPerson({ id: person.id })
      .then((refreshedPerson) => onPersonUpdate(refreshedPerson))
      .catch((error) => handleError(error, $t('errors.failed_to_load_people')));
  };

  const handleSuggestionFeedback = (
    suggestion: PersonFaceSuggestionResponseDto,
    decision: FaceSuggestionFeedbackDecision,
  ) => handleSuggestionBatchFeedback([suggestion], decision);

  const handleSuggestionBatchFeedback = async (
    targetSuggestions: PersonFaceSuggestionResponseDto[],
    decision: FaceSuggestionFeedbackDecision,
  ) => {
    const activeSuggestions = targetSuggestions.filter((suggestion) => !isSuggestionPending(suggestion));
    if (isUpdating || activeSuggestions.length === 0) {
      return;
    }

    const targetIds = activeSuggestions.map(({ id }) => id);
    const targetIdSet = new Set(targetIds);
    const optimisticSuggestions = suggestions.filter(({ id }) => targetIdSet.has(id));
    const remainingSuggestions = suggestions.filter(({ id }) => !targetIdSet.has(id));

    suggestions = remainingSuggestions;
    selectedSuggestionIds = selectedSuggestionIds.filter((id) => !targetIdSet.has(id));
    pendingSuggestionIds = [...pendingSuggestionIds, ...targetIds];

    try {
      const response = await respondToPersonFaceSuggestions({
        id: person.id,
        personFaceSuggestionBatchFeedbackDto: { faceIds: targetIds, decision },
      });

      const failedIds = new Set(response.failed.map(({ faceId }) => faceId));
      const failedSuggestions = optimisticSuggestions.filter(({ id }) => failedIds.has(id));
      if (failedSuggestions.length > 0) {
        suggestions = [...failedSuggestions, ...suggestions];
      }

      if (decision === FaceSuggestionFeedbackDecision.Accepted) {
        featureThumbnailUrlOverride = null;
        const acceptedSuggestions = optimisticSuggestions.filter(({ id }) => !failedIds.has(id));
        faces = [
          ...acceptedSuggestions.map((suggestion) => ({ ...suggestion, person })),
          ...faces.filter(({ id }) => !targetIdSet.has(id)),
        ];
        refreshPersonInBackground();
        void loadHistory();
        toastManager.primary($t('face_suggestions_accepted_count', { values: { count: response.results.length } }));
      } else {
        toastManager.primary($t('face_suggestions_rejected_count', { values: { count: response.results.length } }));
      }

      if (response.failed.length > 0) {
        toastManager.warning($t('face_suggestions_failed_count', { values: { count: response.failed.length } }));
      }

      void refillSuggestionsIfNeeded(suggestions);
    } catch (error) {
      suggestions = [...optimisticSuggestions, ...suggestions];
      selectedSuggestionIds = [...new Set([...selectedSuggestionIds, ...targetIds])];
      handleError(error, $t('errors.unable_to_update_face_suggestion'));
    } finally {
      pendingSuggestionIds = pendingSuggestionIds.filter((id) => !targetIdSet.has(id));
    }
  };

  const handleSkipSuggestion = (suggestion: PersonFaceSuggestionResponseDto) => {
    const remainingSuggestions = suggestions.filter(({ id }) => id !== suggestion.id);
    suggestions = remainingSuggestions;
    selectedSuggestionIds = selectedSuggestionIds.filter((id) => id !== suggestion.id);
    void refillSuggestionsIfNeeded(remainingSuggestions);
  };

  const refillSuggestionsIfNeeded = async (remainingSuggestions: PersonFaceSuggestionResponseDto[]) => {
    if (remainingSuggestions.length > 0 || !hasNextSuggestionPage || isLoadingMoreSuggestions) {
      return;
    }

    await loadSuggestions();
  };

  const handleSkipSelectedSuggestions = () => {
    if (selectedSuggestions.length === 0) {
      return;
    }

    const selectedIds = new Set(selectedSuggestions.map(({ id }) => id));
    const remainingSuggestions = suggestions.filter(({ id }) => !selectedIds.has(id));
    suggestions = remainingSuggestions;
    selectedSuggestionIds = [];
    void refillSuggestionsIfNeeded(remainingSuggestions);
  };

  const handleRegenerateThumbnails = async (targetFaces: Array<Pick<AssetFaceResponseDto, 'id' | 'assetId'>>) => {
    const assetIds = getUniqueAssetIds(targetFaces);
    if (assetIds.length === 0 || isRegeneratingThumbnails) {
      return;
    }

    if (assetIds.length > 1) {
      const confirmed = await modalManager.showDialog({
        prompt: $t('regenerate_thumbnails_confirmation', { values: { count: assetIds.length } }),
        confirmText: $t('refresh_thumbnails'),
      });

      if (!confirmed) {
        return;
      }
    }

    regeneratingThumbnailAssetIds = [...regeneratingThumbnailAssetIds, ...assetIds];
    try {
      await runAssetJobs({
        assetJobsDto: {
          name: AssetJobName.RegenerateThumbnail,
          assetIds,
        },
      });

      for (const face of targetFaces) {
        delete facePreviewCache[face.id];
      }
      brokenPreviewFaceIds = brokenPreviewFaceIds.filter((id) => !targetFaces.some((face) => face.id === id));
      toastManager.primary($t('regenerating_thumbnails'));
    } catch (error) {
      handleError(error, $t('errors.unable_to_submit_job'));
    } finally {
      regeneratingThumbnailAssetIds = regeneratingThumbnailAssetIds.filter((id) => !assetIds.includes(id));
    }
  };

  const isEditableKeyboardTarget = (target: EventTarget | null) => {
    if (!(target instanceof HTMLElement)) {
      return false;
    }

    return ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName) || target.isContentEditable;
  };

  const handleReviewKeyDown = (event: KeyboardEvent) => {
    if (
      !isReviewMode ||
      isUpdating ||
      !activeSuggestion ||
      event.repeat ||
      event.metaKey ||
      event.ctrlKey ||
      event.altKey ||
      isEditableKeyboardTarget(event.target)
    ) {
      return;
    }

    switch (event.key.toLowerCase()) {
      case 's':
      case 'y': {
        event.preventDefault();
        void handleSuggestionFeedback(activeSuggestion, FaceSuggestionFeedbackDecision.Accepted);
        break;
      }
      case 'n': {
        event.preventDefault();
        void handleSuggestionFeedback(activeSuggestion, FaceSuggestionFeedbackDecision.Rejected);
        break;
      }
      case 'k': {
        event.preventDefault();
        handleSkipSuggestion(activeSuggestion);
        break;
      }
    }
  };

  onMount(() => {
    void Promise.all([loadFaces({ reset: true }), loadHistory(), loadSuggestions({ reset: true })]);
  });
</script>

<svelte:document onkeydown={handleReviewKeyDown} />

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

        {#if !isLoadingSuggestions}
          {#if isReviewMode}
            <Button size="small" color="secondary" variant="outline" onclick={() => (isReviewMode = false)}>
              {$t('exit_face_suggestion_review')}
            </Button>
          {:else}
            <Button size="small" disabled={suggestions.length === 0} onclick={() => (isReviewMode = true)}>
              {$t('start_face_suggestion_review')}
            </Button>
          {/if}
        {/if}
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
      {:else if isReviewMode}
        {#if activeSuggestion}
          <article
            class="grid gap-4 overflow-hidden rounded-3xl border border-immich-primary/20 bg-white p-4 shadow-sm dark:border-immich-dark-primary/30 dark:bg-black/20 lg:grid-cols-[minmax(14rem,20rem)_1fr]"
          >
            <div class="relative aspect-square overflow-hidden rounded-2xl bg-gray-100 dark:bg-immich-dark-gray">
              {#await getFacePreview(activeSuggestion)}
                <div class="flex h-full w-full items-center justify-center">
                  <LoadingSpinner />
                </div>
              {:then preview}
                <img
                  src={preview ?? noThumbnailUrl}
                  alt={$t('face_suggestion_preview_alt', { values: { name: person.name || $t('person') } })}
                  class="h-full w-full object-cover"
                  draggable="false"
                />
              {/await}
            </div>

            <div class="flex min-w-0 flex-col justify-between gap-5">
              <div>
                <p
                  class="text-sm font-semibold uppercase tracking-wide text-immich-primary dark:text-immich-dark-primary"
                >
                  {$t('face_suggestion_review_mode')}
                </p>
                <h3 class="mt-2 text-2xl font-semibold">
                  {$t('face_suggestion_question', { values: { name: person.name || $t('person') } })}
                </h3>
                <p class="mt-2 text-sm text-gray-600 dark:text-gray-300">
                  {$t('face_suggestion_review_mode_description')}
                </p>
                <p class="mt-3 text-sm text-gray-500 dark:text-gray-400">
                  {$t('face_suggestion_match_score', {
                    values: { score: formatFaceSuggestionMatchScore(activeSuggestion.distance, $locale) },
                  })} ·
                  {$t('face_suggestion_review_remaining', { values: { count: suggestions.length } })}
                </p>
              </div>

              <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
                <Button
                  leadingIcon={mdiImageCheckOutline}
                  loading={isSuggestionPending(activeSuggestion)}
                  disabled={isUpdating || isSuggestionPending(activeSuggestion)}
                  onclick={() => handleSuggestionFeedback(activeSuggestion, FaceSuggestionFeedbackDecision.Accepted)}
                >
                  {$t('yes')}
                  <span class="ml-2 rounded bg-black/10 px-1.5 py-0.5 text-xs dark:bg-white/15">S/Y</span>
                </Button>

                <Button
                  color="secondary"
                  variant="outline"
                  loading={isSuggestionPending(activeSuggestion)}
                  disabled={isUpdating || isSuggestionPending(activeSuggestion)}
                  onclick={() => handleSuggestionFeedback(activeSuggestion, FaceSuggestionFeedbackDecision.Rejected)}
                >
                  {$t('no')}
                  <span class="ml-2 rounded bg-black/10 px-1.5 py-0.5 text-xs dark:bg-white/15">N</span>
                </Button>

                <Button
                  color="secondary"
                  variant="ghost"
                  disabled={isUpdating || isSuggestionPending(activeSuggestion)}
                  onclick={() => handleSkipSuggestion(activeSuggestion)}
                >
                  {$t('skip')}
                  <span class="ml-2 rounded bg-black/10 px-1.5 py-0.5 text-xs dark:bg-white/15">K</span>
                </Button>
              </div>

              <p class="text-xs text-gray-500 dark:text-gray-400">
                {$t('face_suggestion_review_shortcuts')}
              </p>
            </div>
          </article>
        {/if}
      {:else}
        <div
          class="mb-4 flex flex-col gap-3 rounded-2xl border border-immich-primary/15 bg-white/70 p-3 dark:border-immich-dark-primary/25 dark:bg-black/20"
        >
          <div class="flex flex-wrap items-center gap-2">
            <Button size="small" color="secondary" variant="outline" onclick={toggleAllVisibleSuggestions}>
              {allVisibleSuggestionsSelected ? $t('clear_selection') : $t('select_all_visible')}
            </Button>

            {#if selectedSuggestions.length > 0}
              <Button
                size="small"
                leadingIcon={mdiImageCheckOutline}
                disabled={isUpdating}
                onclick={() =>
                  handleSuggestionBatchFeedback(selectedSuggestions, FaceSuggestionFeedbackDecision.Accepted)}
              >
                {$t('accept_selected_face_suggestions', { values: { count: selectedSuggestions.length } })}
              </Button>

              <Button
                size="small"
                color="secondary"
                variant="outline"
                disabled={isUpdating}
                onclick={() =>
                  handleSuggestionBatchFeedback(selectedSuggestions, FaceSuggestionFeedbackDecision.Rejected)}
              >
                {$t('reject_selected_face_suggestions', { values: { count: selectedSuggestions.length } })}
              </Button>

              <Button size="small" color="secondary" variant="ghost" onclick={handleSkipSelectedSuggestions}>
                {$t('skip_selected_face_suggestions', { values: { count: selectedSuggestions.length } })}
              </Button>
            {/if}
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <Button
              size="small"
              color="secondary"
              variant="outline"
              leadingIcon={mdiImageRefreshOutline}
              loading={isRegeneratingThumbnails}
              disabled={isRegeneratingThumbnails}
              onclick={() => handleRegenerateThumbnails(suggestions)}
            >
              {$t('regenerate_visible_thumbnails')}
            </Button>

            <Button
              size="small"
              color="secondary"
              variant="outline"
              leadingIcon={mdiImageRefreshOutline}
              loading={isRegeneratingThumbnails}
              disabled={isRegeneratingThumbnails || brokenVisibleFaceCount === 0}
              onclick={() => handleRegenerateThumbnails(getBrokenVisibleFaces())}
            >
              {$t('regenerate_broken_thumbnails', { values: { count: brokenVisibleFaceCount } })}
            </Button>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
          {#each suggestions as suggestion (suggestion.id)}
            <article
              class={`overflow-hidden rounded-2xl border bg-white shadow-sm transition dark:bg-black/20 ${
                selectedSuggestionIds.includes(suggestion.id)
                  ? 'border-immich-primary ring-2 ring-immich-primary/40 dark:border-immich-dark-primary dark:ring-immich-dark-primary/40'
                  : 'border-gray-200 dark:border-gray-800'
              }`}
            >
              <div class="grid grid-cols-[6rem_1fr] gap-3 p-3">
                <button
                  type="button"
                  class="relative aspect-square overflow-hidden rounded-xl bg-gray-100 text-left dark:bg-immich-dark-gray"
                  aria-pressed={selectedSuggestionIds.includes(suggestion.id)}
                  aria-label={$t('select_face_suggestion')}
                  onclick={() => toggleSuggestionSelection(suggestion)}
                >
                  {#await getFacePreview(suggestion)}
                    <div class="flex h-full w-full items-center justify-center">
                      <LoadingSpinner />
                    </div>
                  {:then preview}
                    <img
                      src={preview ?? noThumbnailUrl}
                      alt={$t('face_suggestion_preview_alt', { values: { name: person.name || $t('person') } })}
                      class="h-full w-full object-cover"
                      draggable="false"
                    />
                  {/await}
                  <span
                    class={`absolute right-2 top-2 h-5 w-5 rounded-full border-2 ${
                      selectedSuggestionIds.includes(suggestion.id)
                        ? 'border-immich-primary bg-immich-primary dark:border-immich-dark-primary dark:bg-immich-dark-primary'
                        : 'border-white bg-black/40'
                    }`}
                    aria-hidden="true"
                  ></span>
                </button>

                <div class="flex min-w-0 flex-col justify-between gap-3">
                  <div>
                    <p class="font-semibold">
                      {$t('face_suggestion_question', { values: { name: person.name || $t('person') } })}
                    </p>
                    <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                      {$t('face_suggestion_match_score', {
                        values: { score: formatFaceSuggestionMatchScore(suggestion.distance, $locale) },
                      })}
                    </p>
                    {#if getSameAssetSuggestionCount(suggestion) > 1}
                      <Button
                        size="small"
                        color="secondary"
                        variant="ghost"
                        disabled={isUpdating}
                        onclick={() => selectSuggestionsByAsset(suggestion.assetId)}
                      >
                        {$t('select_same_asset_face_suggestions', {
                          values: { count: getSameAssetSuggestionCount(suggestion) },
                        })}
                      </Button>
                    {/if}
                  </div>

                  <div class="grid grid-cols-3 gap-2">
                    <Button
                      size="small"
                      leadingIcon={mdiImageCheckOutline}
                      loading={isSuggestionPending(suggestion)}
                      disabled={isUpdating || isSuggestionPending(suggestion)}
                      onclick={() => handleSuggestionFeedback(suggestion, FaceSuggestionFeedbackDecision.Accepted)}
                    >
                      {$t('yes')}
                    </Button>

                    <Button
                      size="small"
                      color="secondary"
                      variant="outline"
                      loading={isSuggestionPending(suggestion)}
                      disabled={isUpdating || isSuggestionPending(suggestion)}
                      onclick={() => handleSuggestionFeedback(suggestion, FaceSuggestionFeedbackDecision.Rejected)}
                    >
                      {$t('no')}
                    </Button>

                    <Button
                      size="small"
                      color="secondary"
                      variant="ghost"
                      disabled={isUpdating || isSuggestionPending(suggestion)}
                      onclick={() => handleSkipSuggestion(suggestion)}
                    >
                      {$t('skip')}
                    </Button>
                  </div>

                  <Button
                    fullWidth
                    size="small"
                    color="secondary"
                    variant="ghost"
                    leadingIcon={mdiImageRefreshOutline}
                    loading={regeneratingThumbnailAssetIds.includes(suggestion.assetId)}
                    disabled={isRegeneratingThumbnails}
                    onclick={() => handleRegenerateThumbnails([suggestion])}
                  >
                    {$t('regenerate_thumbnail')}
                  </Button>
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
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <Button
          size="small"
          color="secondary"
          variant="outline"
          leadingIcon={mdiImageRefreshOutline}
          loading={isRegeneratingThumbnails}
          disabled={isRegeneratingThumbnails}
          onclick={() => handleRegenerateThumbnails(faces)}
        >
          {$t('regenerate_visible_thumbnails')}
        </Button>

        <Button
          size="small"
          color="secondary"
          variant="outline"
          leadingIcon={mdiImageRefreshOutline}
          loading={isRegeneratingThumbnails}
          disabled={isRegeneratingThumbnails || brokenVisibleFaceCount === 0}
          onclick={() => handleRegenerateThumbnails(getBrokenVisibleFaces())}
        >
          {$t('regenerate_broken_thumbnails', { values: { count: brokenVisibleFaceCount } })}
        </Button>
      </div>

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
                  src={preview ?? noThumbnailUrl}
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
                leadingIcon={mdiImageRefreshOutline}
                loading={regeneratingThumbnailAssetIds.includes(face.assetId)}
                disabled={isRegeneratingThumbnails}
                onclick={() => handleRegenerateThumbnails([face])}
              >
                {$t('regenerate_thumbnail')}
              </Button>

              <Button
                fullWidth
                size="small"
                color="secondary"
                variant="ghost"
                href={Route.viewAsset({ id: face.assetId }, { previousRoute: referencesRoute })}
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
