<script lang="ts">
  import SearchPeople from '$lib/components/faces-page/PeopleSearch.svelte';
  import { timeBeforeShowLoadingSpinner } from '$lib/constants';
  import { assetViewerManager } from '$lib/managers/asset-viewer-manager.svelte';
  import { getPeopleThumbnailUrl, handlePromiseError } from '$lib/utils';
  import { handleError } from '$lib/utils/handle-error';
  import { zoomImageToBase64 } from '$lib/utils/people-utils';
  import { getPersonNameWithHiddenValue } from '$lib/utils/person';
  import { AssetTypeEnum, getAllPeople, type AssetFaceResponseDto, type PersonResponseDto } from '@immich/sdk';
  import { IconButton, LoadingSpinner } from '@immich/ui';
  import { mdiArrowLeftThin, mdiClose, mdiMagnify, mdiPlus } from '@mdi/js';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';
  import { linear } from 'svelte/easing';
  import { fly } from 'svelte/transition';
  import ImageThumbnail from '../assets/thumbnail/ImageThumbnail.svelte';

  interface Props {
    editedFace: AssetFaceResponseDto;
    assetId: string;
    assetType: AssetTypeEnum;
    onClose: () => void;
    onCreatePerson: (person: { name: string; featurePhoto: string }) => void;
    onReassign: (person: PersonResponseDto) => void;
  }

  let { editedFace, assetId, assetType, onClose, onCreatePerson, onReassign }: Props = $props();

  let allPeople: PersonResponseDto[] = $state([]);

  let isShowLoadingPeople = $state(false);

  async function loadPeople() {
    const timeout = setTimeout(() => (isShowLoadingPeople = true), timeBeforeShowLoadingSpinner);
    try {
      const { people } = await getAllPeople({ withHidden: true, closestAssetId: assetId });
      allPeople = people;
    } catch (error) {
      handleError(error, $t('errors.cant_get_faces'));
    } finally {
      clearTimeout(timeout);
    }
    isShowLoadingPeople = false;
  }

  // loading spinners
  let isShowLoadingNewPerson = $state(false);
  let isShowLoadingSearch = $state(false);
  let isCreatingPerson = $state(false);
  let newPersonName = $state('');
  let newPersonFeaturePhoto: string | undefined = $state();

  // search people
  let searchedPeople: PersonResponseDto[] = $state([]);
  let searchFaces = $state(false);
  let searchName = $state('');

  let showPeople = $derived(searchName ? searchedPeople : allPeople.filter((person) => !person.isHidden));
  let trimmedNewPersonName = $derived(newPersonName.trim());

  onMount(() => {
    handlePromiseError(loadPeople());
  });

  const handleStartCreatePerson = async () => {
    const timeout = setTimeout(() => (isShowLoadingNewPerson = true), timeBeforeShowLoadingSpinner);

    const newFeaturePhoto = await zoomImageToBase64(editedFace, assetId, assetType, assetViewerManager.imgRef);

    clearTimeout(timeout);
    isShowLoadingNewPerson = false;

    if (!newFeaturePhoto) {
      handleError(new Error('Unable to create person preview'), $t('errors.cant_get_faces'));
      return;
    }

    newPersonFeaturePhoto = newFeaturePhoto;
    isCreatingPerson = true;
  };

  const handleCancelCreatePerson = () => {
    newPersonName = '';
    newPersonFeaturePhoto = undefined;
    isCreatingPerson = false;
  };

  const handleConfirmCreatePerson = () => {
    if (!trimmedNewPersonName || !newPersonFeaturePhoto) {
      return;
    }

    onCreatePerson({ name: trimmedNewPersonName, featurePhoto: newPersonFeaturePhoto });
  };
</script>

<section
  transition:fly={{ x: 360, duration: 100, easing: linear }}
  class="absolute top-0 h-full w-90 overflow-x-hidden p-2 dark:text-immich-dark-fg bg-light"
>
  <div class="flex place-items-center justify-between gap-2">
    {#if isCreatingPerson}
      <div class="flex items-center gap-2">
        <IconButton
          color="secondary"
          variant="ghost"
          shape="round"
          icon={mdiArrowLeftThin}
          aria-label={$t('back')}
          onclick={handleCancelCreatePerson}
        />
        <p class="flex text-lg text-immich-fg dark:text-immich-dark-fg">{$t('create_person')}</p>
      </div>
    {:else if !searchFaces}
      <div class="flex items-center gap-2">
        <IconButton
          color="secondary"
          variant="ghost"
          shape="round"
          icon={mdiArrowLeftThin}
          aria-label={$t('back')}
          onclick={onClose}
        />
        <p class="flex text-lg text-immich-fg dark:text-immich-dark-fg">{$t('select_face')}</p>
      </div>
      <div class="flex justify-end gap-2">
        <IconButton
          color="secondary"
          variant="ghost"
          shape="round"
          icon={mdiMagnify}
          aria-label={$t('search_for_existing_person')}
          onclick={() => {
            searchFaces = true;
          }}
        />
        {#if !isShowLoadingNewPerson}
          <IconButton
            color="secondary"
            variant="ghost"
            shape="round"
            icon={mdiPlus}
            aria-label={$t('create_new_person')}
            onclick={handleStartCreatePerson}
          />
        {:else}
          <div class="flex place-content-center place-items-center">
            <LoadingSpinner />
          </div>
        {/if}
      </div>
    {:else}
      <IconButton
        color="secondary"
        variant="ghost"
        shape="round"
        icon={mdiArrowLeftThin}
        aria-label={$t('back')}
        onclick={onClose}
      />
      <div class="w-full flex">
        <SearchPeople
          type="input"
          bind:searchName
          bind:showLoadingSpinner={isShowLoadingSearch}
          bind:searchedPeopleLocal={searchedPeople}
        />
        {#if isShowLoadingSearch}
          <div>
            <LoadingSpinner />
          </div>
        {/if}
      </div>
      <IconButton
        color="secondary"
        variant="ghost"
        shape="round"
        icon={mdiClose}
        aria-label={$t('cancel_search')}
        onclick={() => (searchFaces = false)}
      />
    {/if}
  </div>
  <div class="px-4 py-4 text-sm">
    {#if isCreatingPerson}
      <p class="mb-4 mt-4 text-sm text-gray-600 dark:text-gray-300">{$t('create_person_subtitle')}</p>
      {#if newPersonFeaturePhoto}
        <div class="mb-4 flex justify-center">
          <ImageThumbnail
            curve
            shadow
            url={newPersonFeaturePhoto}
            altText={$t('preview')}
            title={$t('preview')}
            widthStyle="120px"
            heightStyle="120px"
          />
        </div>
      {/if}
      <label class="mb-2 block font-medium" for="new-person-name">{$t('name')}</label>
      <input
        id="new-person-name"
        class="w-full rounded-lg border border-gray-300 bg-white px-3 py-2 text-black outline-none focus:border-immich-primary focus:ring-2 focus:ring-immich-primary/40 dark:border-gray-700 dark:bg-black dark:text-white"
        bind:value={newPersonName}
        onkeydown={(event) => {
          if (event.key === 'Enter') {
            handleConfirmCreatePerson();
          }
        }}
      />
      <div class="mt-4 flex gap-2">
        <button
          type="button"
          class="rounded-lg px-3 py-2 text-immich-fg hover:bg-gray-200 dark:text-immich-dark-fg hover:dark:bg-gray-700"
          onclick={handleCancelCreatePerson}
        >
          {$t('cancel')}
        </button>
        <button
          type="button"
          class="rounded-lg bg-immich-primary px-3 py-2 text-white disabled:cursor-not-allowed disabled:opacity-50"
          disabled={!trimmedNewPersonName}
          onclick={handleConfirmCreatePerson}
        >
          {$t('create_person')}
        </button>
      </div>
    {:else}
      <h2 class="mb-8 mt-4">{$t('all_people')}</h2>
      {#if isShowLoadingPeople}
        <div class="flex w-full justify-center">
          <LoadingSpinner />
        </div>
      {:else if showPeople.length === 0}
        <p class="text-gray-500 dark:text-gray-400">{$t('no_people_found')}</p>
      {:else}
        <div class="immich-scrollbar mt-4 flex flex-wrap gap-2 overflow-y-auto">
          {#each showPeople as person (person.id)}
            {#if !editedFace.person || person.id !== editedFace.person.id}
              <div class="w-fit">
                <button type="button" class="w-22.5" onclick={() => onReassign(person)}>
                  <div class="relative">
                    <ImageThumbnail
                      curve
                      shadow
                      url={getPeopleThumbnailUrl(person)}
                      altText={$getPersonNameWithHiddenValue(person.name, person.isHidden)}
                      title={$getPersonNameWithHiddenValue(person.name, person.isHidden)}
                      widthStyle="90px"
                      heightStyle="90px"
                      hidden={person.isHidden}
                    />
                  </div>

                  <p
                    class="mt-1 truncate font-medium"
                    title={$getPersonNameWithHiddenValue(person.name, person.isHidden)}
                  >
                    {person.name}
                  </p>
                </button>
              </div>
            {/if}
          {/each}
        </div>
      {/if}
    {/if}
  </div>
</section>
