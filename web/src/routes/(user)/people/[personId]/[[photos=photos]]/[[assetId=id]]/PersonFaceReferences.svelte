<script lang="ts">
  import ImageThumbnail from '$lib/components/assets/thumbnail/ImageThumbnail.svelte';
  import { Route } from '$lib/route';
  import { getFaceSourceImageUrl, getPeopleThumbnailUrl } from '$lib/utils';
  import { handleError } from '$lib/utils/handle-error';
  import { getPersonFaces, updatePerson, type AssetFaceResponseDto, type PersonResponseDto } from '@immich/sdk';
  import { Button, LoadingSpinner, toastManager } from '@immich/ui';
  import { mdiImageCheckOutline, mdiOpenInNew } from '@mdi/js';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';

  interface Props {
    person: PersonResponseDto;
    onPersonUpdate: (person: PersonResponseDto) => void;
  }

  let { person, onPersonUpdate }: Props = $props();

  const pageSize = 48;
  const facePreviewCache = new Map<string, Promise<string | null>>();

  let faces: AssetFaceResponseDto[] = $state([]);
  let page = $state(1);
  let hasNextPage = $state(false);
  let isLoading = $state(true);
  let isLoadingMore = $state(false);
  let updatingFaceId = $state<string | null>(null);

  const loadFacePreview = async (face: AssetFaceResponseDto) => {
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

  const getFacePreview = (face: AssetFaceResponseDto) => {
    const cached = facePreviewCache.get(face.id);
    if (cached) {
      return cached;
    }

    const preview = loadFacePreview(face);
    facePreviewCache.set(face.id, preview);
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

  const handleSetFeaturePhoto = async (face: AssetFaceResponseDto) => {
    if (updatingFaceId) {
      return;
    }

    updatingFaceId = face.id;
    try {
      const updatedPerson = await updatePerson({
        id: person.id,
        personUpdateDto: { featureFaceId: face.id },
      });

      onPersonUpdate(updatedPerson);
      toastManager.primary($t('feature_photo_updated'));
    } catch (error) {
      handleError(error, $t('errors.unable_to_set_feature_photo'));
    } finally {
      updatingFaceId = null;
    }
  };

  onMount(() => {
    void loadFaces({ reset: true });
  });
</script>

<section class="h-full overflow-y-auto px-4 py-12 text-primary sm:px-6 lg:px-10">
  <div class="mb-8 max-w-3xl">
    <div class="flex items-center gap-4">
      <ImageThumbnail
        circle
        shadow
        url={getPeopleThumbnailUrl(person)}
        altText={person.name}
        widthStyle="4rem"
        heightStyle="4rem"
      />

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
  {:else if faces.length === 0}
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
              disabled={!!updatingFaceId}
              onclick={() => handleSetFeaturePhoto(face)}
            >
              {$t('set_as_featured_photo')}
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
</section>
