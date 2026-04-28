<script lang="ts">
  import { goto } from '$app/navigation';
  import ImageThumbnail from '$lib/components/assets/thumbnail/ImageThumbnail.svelte';
  import { Route } from '$lib/route';
  import { getFaceSourceImageUrl, getPeopleThumbnailUrl } from '$lib/utils';
  import { handleError } from '$lib/utils/handle-error';
  import {
    FaceSuggestionFeedbackDecision,
    getFaceSuggestionSummary,
    getPersonFaceSuggestions,
    respondToPersonFaceSuggestion,
    type PersonFaceSuggestionResponseDto,
    type PersonFaceSuggestionSummaryItemResponseDto,
  } from '@immich/sdk';
  import { Button, Icon, LoadingSpinner, toastManager } from '@immich/ui';
  import { mdiArrowLeft, mdiFaceRecognition, mdiImageCheckOutline, mdiOpenInNew } from '@mdi/js';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';

  type FacePreviewSource = Pick<
    PersonFaceSuggestionResponseDto,
    'id' | 'imageWidth' | 'imageHeight' | 'boundingBoxX1' | 'boundingBoxX2' | 'boundingBoxY1' | 'boundingBoxY2'
  >;

  const pageSize = 10;
  const peopleLimit = 100;
  const facePreviewCache: Record<string, Promise<string | null> | undefined> = {};

  let queue: PersonFaceSuggestionSummaryItemResponseDto[] = $state([]);
  let pendingPeople = $state(0);
  let scannedPeople = $state(0);
  let hasMorePeople = $state(false);
  let isLoading = $state(true);
  let isResponding = $state(false);
  let isRefreshingQueue = $state(false);

  const activeItem = $derived(queue[0] ?? null);
  const activePersonName = $derived(activeItem?.person.name || $t('person'));
  const remainingQueueCount = $derived(Math.max(queue.length - 1, 0));
  const pendingLabel = $derived(
    hasMorePeople
      ? $t('face_suggestions_pending_count_more', { values: { count: pendingPeople } })
      : $t('face_suggestions_pending_count', { values: { count: pendingPeople } }),
  );

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

  const loadQueue = async ({ reset = false } = {}) => {
    if (reset) {
      isLoading = true;
    } else {
      isRefreshingQueue = true;
    }

    try {
      const summary = await getFaceSuggestionSummary({ size: pageSize, peopleLimit });
      queue = summary.people;
      pendingPeople = summary.pendingPeople;
      scannedPeople = summary.scannedPeople;
      hasMorePeople = summary.hasMorePeople;
    } catch (error) {
      handleError(error, $t('errors.unable_to_load_face_suggestions'));
    } finally {
      isLoading = false;
      isRefreshingQueue = false;
    }
  };

  const replaceCurrentSuggestion = async (current: PersonFaceSuggestionSummaryItemResponseDto) => {
    const response = await getPersonFaceSuggestions({ id: current.person.id, page: 1, size: 1 });
    const [nextSuggestion] = response.suggestions;

    if (nextSuggestion) {
      queue = [{ person: current.person, suggestion: nextSuggestion }, ...queue.slice(1)];
      return;
    }

    queue = queue.slice(1);
    pendingPeople = Math.max(0, pendingPeople - 1);

    if (queue.length === 0 && (hasMorePeople || pendingPeople > 0)) {
      await loadQueue();
    }
  };

  const handleSuggestionFeedback = async (decision: FaceSuggestionFeedbackDecision) => {
    if (!activeItem || isResponding) {
      return;
    }

    const current = activeItem;
    isResponding = true;
    try {
      await respondToPersonFaceSuggestion({
        id: current.person.id,
        faceId: current.suggestion.id,
        personFaceSuggestionFeedbackDto: { decision },
      });

      if (decision === FaceSuggestionFeedbackDecision.Accepted) {
        await loadQueue();
      } else {
        await replaceCurrentSuggestion(current);
      }
      toastManager.primary(
        decision === FaceSuggestionFeedbackDecision.Accepted
          ? $t('face_suggestion_accepted')
          : $t('face_suggestion_rejected'),
      );
    } catch (error) {
      handleError(error, $t('errors.unable_to_update_face_suggestion'));
    } finally {
      isResponding = false;
    }
  };

  const handleSkipSuggestion = () => {
    if (!activeItem || queue.length <= 1) {
      return;
    }

    queue = [...queue.slice(1), activeItem];
  };

  const isEditableKeyboardTarget = (target: EventTarget | null) => {
    if (!(target instanceof HTMLElement)) {
      return false;
    }

    return ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName) || target.isContentEditable;
  };

  const handleKeyDown = (event: KeyboardEvent) => {
    if (
      !activeItem ||
      isResponding ||
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
        void handleSuggestionFeedback(FaceSuggestionFeedbackDecision.Accepted);
        break;
      }
      case 'n': {
        event.preventDefault();
        void handleSuggestionFeedback(FaceSuggestionFeedbackDecision.Rejected);
        break;
      }
      case 'k': {
        event.preventDefault();
        handleSkipSuggestion();
        break;
      }
    }
  };

  onMount(() => {
    void loadQueue({ reset: true });
  });
</script>

<svelte:document onkeydown={handleKeyDown} />

<main class="min-h-dvh bg-gray-50 px-4 pt-(--navbar-height) text-primary dark:bg-black md:px-8 md:pt-(--navbar-height-md)">
  <section class="mx-auto flex max-w-6xl flex-col gap-6 py-8">
    <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <div class="flex items-center gap-4">
        <Button
          size="small"
          color="secondary"
          variant="ghost"
          leadingIcon={mdiArrowLeft}
          onclick={() => goto(Route.people())}
        >
          {$t('back')}
        </Button>
        <div>
          <h1 class="text-2xl font-semibold">{$t('face_suggestion_inbox_title')}</h1>
          <p class="mt-1 text-sm text-gray-600 dark:text-gray-300">
            {$t('face_suggestion_inbox_description')}
          </p>
        </div>
      </div>

      <Button
        size="small"
        color="secondary"
        variant="outline"
        loading={isRefreshingQueue}
        disabled={isLoading || isRefreshingQueue}
        onclick={() => loadQueue()}
      >
        {$t('refresh')}
      </Button>
    </div>

    {#if isLoading}
      <div class="flex h-96 items-center justify-center rounded-3xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-immich-dark-gray">
        <LoadingSpinner />
      </div>
    {:else if !activeItem}
      <div
        class="flex min-h-96 flex-col items-center justify-center rounded-3xl border border-dashed border-gray-300 bg-white p-8 text-center dark:border-gray-700 dark:bg-immich-dark-gray"
      >
        <div class="mb-4 flex h-16 w-16 items-center justify-center rounded-full bg-immich-primary/10 text-primary dark:bg-immich-dark-primary/20 dark:text-immich-dark-primary">
          <Icon icon={mdiFaceRecognition} size="36" aria-hidden />
        </div>
        <h2 class="text-xl font-semibold">{$t('face_suggestion_inbox_empty_title')}</h2>
        <p class="mt-2 max-w-xl text-sm text-gray-600 dark:text-gray-300">
          {$t('face_suggestion_inbox_empty_description')}
        </p>
      </div>
    {:else}
      <div class="grid gap-6 lg:grid-cols-[minmax(20rem,28rem)_1fr]">
        <article
          class="overflow-hidden rounded-3xl border border-gray-200 bg-white shadow-sm dark:border-gray-800 dark:bg-immich-dark-gray"
        >
          <div class="relative aspect-square bg-gray-100 dark:bg-black/20">
            {#await getFacePreview(activeItem.suggestion)}
              <div class="flex h-full w-full items-center justify-center">
                <LoadingSpinner />
              </div>
            {:then preview}
              <img
                src={preview ?? '/src/lib/assets/no-thumbnail.png'}
                alt={$t('face_suggestion_preview_alt', { values: { name: activePersonName } })}
                class="h-full w-full object-cover"
                draggable="false"
              />
            {/await}
          </div>

          <div class="flex items-center gap-3 border-t border-gray-200 p-4 dark:border-gray-800">
            <ImageThumbnail
              circle
              shadow
              url={getPeopleThumbnailUrl(activeItem.person)}
              altText={activePersonName}
              widthStyle="3rem"
              heightStyle="3rem"
            />
            <div class="min-w-0">
              <p class="truncate text-lg font-semibold">{activePersonName}</p>
              <p class="text-sm text-gray-500 dark:text-gray-400">
                {$t('face_suggestion_distance', { values: { distance: activeItem.suggestion.distance.toFixed(3) } })}
              </p>
            </div>
          </div>
        </article>

        <section
          class="flex flex-col justify-between gap-8 rounded-3xl border border-immich-primary/20 bg-immich-primary/5 p-5 dark:border-immich-dark-primary/30 dark:bg-immich-dark-primary/20"
        >
          <div>
            <p class="text-sm font-semibold uppercase tracking-wide text-immich-primary dark:text-immich-dark-primary">
              {$t('face_suggestion_review_mode')}
            </p>
            <h2 class="mt-3 text-3xl font-semibold">
              {$t('face_suggestion_question', { values: { name: activePersonName } })}
            </h2>
            <p class="mt-3 max-w-2xl text-sm text-gray-600 dark:text-gray-300">
              {$t('face_suggestion_inbox_review_description')}
            </p>

            <div class="mt-6 grid gap-3 sm:grid-cols-3">
              <div class="rounded-2xl bg-white p-4 dark:bg-black/20">
                <p class="text-2xl font-semibold">{pendingPeople}{hasMorePeople ? '+' : ''}</p>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">{pendingLabel}</p>
              </div>
              <div class="rounded-2xl bg-white p-4 dark:bg-black/20">
                <p class="text-2xl font-semibold">{remainingQueueCount}</p>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">{$t('face_suggestions_queue_remaining')}</p>
              </div>
              <div class="rounded-2xl bg-white p-4 dark:bg-black/20">
                <p class="text-2xl font-semibold">{scannedPeople}</p>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">{$t('face_suggestions_scanned_people')}</p>
              </div>
            </div>
          </div>

          <div class="space-y-4">
            <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <Button
                leadingIcon={mdiImageCheckOutline}
                loading={isResponding}
                disabled={isResponding}
                onclick={() => handleSuggestionFeedback(FaceSuggestionFeedbackDecision.Accepted)}
              >
                {$t('yes')}
                <span class="ml-2 rounded bg-black/10 px-1.5 py-0.5 text-xs dark:bg-white/15">S/Y</span>
              </Button>

              <Button
                color="secondary"
                variant="outline"
                loading={isResponding}
                disabled={isResponding}
                onclick={() => handleSuggestionFeedback(FaceSuggestionFeedbackDecision.Rejected)}
              >
                {$t('no')}
                <span class="ml-2 rounded bg-black/10 px-1.5 py-0.5 text-xs dark:bg-white/15">N</span>
              </Button>

              <Button
                color="secondary"
                variant="ghost"
                disabled={isResponding || queue.length <= 1}
                onclick={handleSkipSuggestion}
              >
                {$t('skip')}
                <span class="ml-2 rounded bg-black/10 px-1.5 py-0.5 text-xs dark:bg-white/15">K</span>
              </Button>
            </div>

            <div class="flex flex-col gap-2 sm:flex-row">
              <Button
                size="small"
                color="secondary"
                variant="ghost"
                leadingIcon={mdiOpenInNew}
                href={Route.viewAsset({ id: activeItem.suggestion.assetId })}
              >
                {$t('view')}
              </Button>
              <Button
                size="small"
                color="secondary"
                variant="ghost"
                leadingIcon={mdiFaceRecognition}
                href={Route.viewPerson(activeItem.person, {
                  previousRoute: Route.faceSuggestions(),
                  action: 'references',
                })}
              >
                {$t('manage_face_references')}
              </Button>
            </div>

            <p class="text-xs text-gray-500 dark:text-gray-400">
              {$t('face_suggestion_review_shortcuts')}
            </p>
          </div>
        </section>
      </div>
    {/if}
  </section>
</main>
