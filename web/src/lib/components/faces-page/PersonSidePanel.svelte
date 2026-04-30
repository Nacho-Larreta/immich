<script lang="ts">
  import { shortcut } from '$lib/actions/shortcut';
  import noThumbnailUrl from '$lib/assets/no-thumbnail.png';
  import OnEvents from '$lib/components/OnEvents.svelte';
  import { timeBeforeShowLoadingSpinner } from '$lib/constants';
  import { assetViewerManager } from '$lib/managers/asset-viewer-manager.svelte';
  import { eventManager } from '$lib/managers/event-manager.svelte';
  import { boundingBoxesArray } from '$lib/stores/people.store';
  import { getPeopleThumbnailUrl, handlePromiseError } from '$lib/utils';
  import { handleError } from '$lib/utils/handle-error';
  import { zoomImageToBase64 } from '$lib/utils/people-utils';
  import { getPersonNameWithHiddenValue } from '$lib/utils/person';
  import {
    AssetTypeEnum,
    createPerson,
    deleteFace,
    getFaces,
    reassignFacesById,
    updatePerson,
    type AssetFaceResponseDto,
    type PersonResponseDto,
  } from '@immich/sdk';
  import { Icon, IconButton, LoadingSpinner, modalManager, toastManager } from '@immich/ui';
  import {
    mdiAccountMultipleCheckOutline,
    mdiArrowLeftThin,
    mdiChevronDown,
    mdiCheckCircle,
    mdiCircleOutline,
    mdiFaceManProfile,
    mdiPencil,
    mdiRestart,
    mdiTrashCan,
  } from '@mdi/js';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';
  import { linear } from 'svelte/easing';
  import { SvelteMap } from 'svelte/reactivity';
  import { fly } from 'svelte/transition';
  import ImageThumbnail from '../assets/thumbnail/ImageThumbnail.svelte';
  import AssignFaceSidePanel from './AssignFaceSidePanel.svelte';

  interface Props {
    assetId: string;
    assetType: AssetTypeEnum;
    onClose: () => void;
    onRefresh: () => void;
  }

  type FaceGroup = {
    id: string;
    face: AssetFaceResponseDto;
    faces: AssetFaceResponseDto[];
    person: PersonResponseDto | null;
    parentId?: string;
  };

  type PendingPersonCreate = {
    name: string;
    featurePhoto: string;
  };

  let { assetId, assetType, onClose, onRefresh }: Props = $props();

  // keep track of the changes
  let peopleToCreate: string[] = [];
  let assetFaceGenerated: string[] = [];

  // faces
  let peopleWithFaces: AssetFaceResponseDto[] = $state([]);
  let selectedPersonToReassign: Record<string, PersonResponseDto> = $state({});
  let selectedPersonToCreate: Record<string, PendingPersonCreate> = $state({});
  let selectedFaceGroupIds: string[] = $state([]);
  let expandedFaceGroupIds: string[] = $state([]);
  let editedFace: AssetFaceResponseDto | undefined = $state();
  let editedFaceGroupId: string | undefined = $state();
  let editedFaceGroupIds: string[] = $state([]);
  let updatingFeatureFaceIds: string[] = $state([]);

  // loading spinners
  let isShowLoadingDone = $state(false);
  let isShowLoadingPeople = $state(false);

  // search people
  let showSelectedFaces = $state(false);

  // timers
  let loaderLoadingDoneTimeout: ReturnType<typeof setTimeout>;
  let automaticRefreshTimeout: ReturnType<typeof setTimeout>;

  const thumbnailWidth = '90px';

  const groupedFaceGroups = $derived.by((): FaceGroup[] => {
    const groups = new SvelteMap<string, FaceGroup>();

    for (const face of peopleWithFaces) {
      const id = face.person ? `person:${face.person.id}` : `face:${face.id}`;
      const group = groups.get(id);

      if (group) {
        group.faces.push(face);
      } else {
        groups.set(id, { id, face, faces: [face], person: face.person });
      }
    }

    return [...groups.values()];
  });

  const hasPendingFaceChange = (face: AssetFaceResponseDto) =>
    Boolean(selectedPersonToCreate[`face:${face.id}`] || selectedPersonToReassign[`face:${face.id}`]);

  const faceGroups = $derived.by((): FaceGroup[] =>
    groupedFaceGroups.flatMap((faceGroup) => {
      const isExpanded =
        expandedFaceGroupIds.includes(faceGroup.id) || faceGroup.faces.some((face) => hasPendingFaceChange(face));

      if (faceGroup.faces.length <= 1 || !isExpanded) {
        return [faceGroup];
      }

      return faceGroup.faces.map((face) => ({
        id: `face:${face.id}`,
        face,
        faces: [face],
        person: face.person ?? null,
        parentId: faceGroup.id,
      }));
    }),
  );

  const selectedFaceGroups = $derived(faceGroups.filter((faceGroup) => selectedFaceGroupIds.includes(faceGroup.id)));
  const selectedFaceCount = $derived(
    selectedFaceGroups.reduce((count, faceGroup) => count + faceGroup.faces.length, 0),
  );

  async function loadPeople() {
    const timeout = setTimeout(() => (isShowLoadingPeople = true), timeBeforeShowLoadingSpinner);
    try {
      peopleWithFaces = await getFaces({ id: assetId });
    } catch (error) {
      handleError(error, $t('errors.cant_get_faces'));
    } finally {
      clearTimeout(timeout);
    }
    isShowLoadingPeople = false;
  }

  const onPersonThumbnailReady = ({ id }: { id: string }) => {
    assetFaceGenerated.push(id);
    if (isEqual(assetFaceGenerated, peopleToCreate) && loaderLoadingDoneTimeout && automaticRefreshTimeout) {
      clearTimeout(loaderLoadingDoneTimeout);
      clearTimeout(automaticRefreshTimeout);
      onRefresh();
    }
  };

  onMount(() => {
    handlePromiseError(loadPeople());
  });

  const isEqual = (a: string[], b: string[]): boolean => {
    return b.every((valueB) => a.includes(valueB));
  };

  const handleReset = (id: string) => {
    if (selectedPersonToReassign[id]) {
      delete selectedPersonToReassign[id];
    }
    if (selectedPersonToCreate[id]) {
      delete selectedPersonToCreate[id];
    }
    selectedFaceGroupIds = selectedFaceGroupIds.filter((faceGroupId) => faceGroupId !== id);
  };

  const countChangedFaces = () => {
    let count = 0;

    for (const faceGroup of faceGroups) {
      if (selectedPersonToCreate[faceGroup.id] || selectedPersonToReassign[faceGroup.id]) {
        count += faceGroup.faces.length;
      }
    }

    return count;
  };

  const handleEditFaces = async () => {
    loaderLoadingDoneTimeout = setTimeout(() => (isShowLoadingDone = true), timeBeforeShowLoadingSpinner);
    const numberOfChanges = Object.keys(selectedPersonToCreate).length + Object.keys(selectedPersonToReassign).length;
    const numberOfChangedFaces = countChangedFaces();

    if (numberOfChanges > 0) {
      if (numberOfChangedFaces > 1) {
        const isConfirmed = await modalManager.showDialog({
          prompt: $t('confirm_apply_face_changes', { values: { count: numberOfChangedFaces } }),
          confirmText: $t('confirm'),
        });

        if (!isConfirmed) {
          clearTimeout(loaderLoadingDoneTimeout);
          isShowLoadingDone = false;
          return;
        }
      }

      try {
        peopleToCreate = [];
        assetFaceGenerated = [];
        const createdPersonByFeaturePhoto = new SvelteMap<string, string>();

        for (const faceGroup of faceGroups) {
          const personId = selectedPersonToReassign[faceGroup.id]?.id;

          if (personId) {
            for (const face of faceGroup.faces) {
              await reassignFacesById({
                id: personId,
                faceDto: { id: face.id },
              });
            }
          } else if (selectedPersonToCreate[faceGroup.id]) {
            const personToCreate = selectedPersonToCreate[faceGroup.id];
            const featurePhoto = personToCreate.featurePhoto;
            const pendingPersonKey = `${personToCreate.name}:${featurePhoto}`;
            let personId = createdPersonByFeaturePhoto.get(pendingPersonKey);

            if (!personId) {
              const data = await createPerson({ personCreateDto: { name: personToCreate.name } });
              personId = data.id;
              peopleToCreate.push(data.id);
              createdPersonByFeaturePhoto.set(pendingPersonKey, data.id);
            }

            for (const face of faceGroup.faces) {
              await reassignFacesById({
                id: personId,
                faceDto: { id: face.id },
              });
            }
          }
        }

        toastManager.primary($t('people_edits_count', { values: { count: numberOfChanges } }));
      } catch (error) {
        handleError(error, $t('errors.cant_apply_changes'));
      }
    }

    isShowLoadingDone = false;
    if (peopleToCreate.length === 0) {
      clearTimeout(loaderLoadingDoneTimeout);
      onRefresh();
    } else {
      automaticRefreshTimeout = setTimeout(onRefresh, 15_000);
    }
  };

  const getEditedFaceGroupIds = () =>
    editedFaceGroupIds.length > 0 ? editedFaceGroupIds : editedFaceGroupId ? [editedFaceGroupId] : [];

  const handleCreatePerson = (personToCreate: PendingPersonCreate) => {
    if (personToCreate.featurePhoto) {
      for (const faceGroupId of getEditedFaceGroupIds()) {
        selectedPersonToCreate[faceGroupId] = personToCreate;
        delete selectedPersonToReassign[faceGroupId];
      }
    }
    selectedFaceGroupIds = [];
    editedFaceGroupIds = [];
    editedFaceGroupId = undefined;
    showSelectedFaces = false;
  };

  const handleReassignFace = (person: PersonResponseDto | null) => {
    if (person) {
      for (const faceGroupId of getEditedFaceGroupIds()) {
        selectedPersonToReassign[faceGroupId] = person;
        delete selectedPersonToCreate[faceGroupId];
      }
    }
    selectedFaceGroupIds = [];
    editedFaceGroupIds = [];
    editedFaceGroupId = undefined;
    showSelectedFaces = false;
  };

  const handleFacePicker = (faceGroup: FaceGroup) => {
    editedFace = faceGroup.face;
    editedFaceGroupId = faceGroup.id;
    editedFaceGroupIds = [];
    showSelectedFaces = true;
  };

  const handleExpandFaceGroup = (faceGroup: FaceGroup) => {
    expandedFaceGroupIds = [...new Set([...expandedFaceGroupIds, faceGroup.id])];
  };

  const handleCollapseFaceGroups = () => {
    expandedFaceGroupIds = [];
  };

  const isSelectableFaceGroup = (faceGroup: FaceGroup) =>
    !faceGroup.person && !selectedPersonToCreate[faceGroup.id] && !selectedPersonToReassign[faceGroup.id];

  const isFaceGroupSelected = (faceGroup: FaceGroup) => selectedFaceGroupIds.includes(faceGroup.id);

  const toggleFaceGroupSelection = (faceGroup: FaceGroup) => {
    if (!isSelectableFaceGroup(faceGroup)) {
      return;
    }

    selectedFaceGroupIds = isFaceGroupSelected(faceGroup)
      ? selectedFaceGroupIds.filter((faceGroupId) => faceGroupId !== faceGroup.id)
      : [...selectedFaceGroupIds, faceGroup.id];
  };

  const clearSelectedFaceGroups = () => {
    selectedFaceGroupIds = [];
  };

  const canSetFeatureFace = (faceGroup: FaceGroup) =>
    Boolean(faceGroup.person) &&
    faceGroup.faces.length === 1 &&
    !selectedPersonToCreate[faceGroup.id] &&
    !selectedPersonToReassign[faceGroup.id];

  const isUpdatingFeatureFace = (faceGroup: FaceGroup) => updatingFeatureFaceIds.includes(faceGroup.face.id);

  const handleSetFeatureFace = async (faceGroup: FaceGroup) => {
    if (!faceGroup.person || isUpdatingFeatureFace(faceGroup)) {
      return;
    }

    const faceId = faceGroup.face.id;
    updatingFeatureFaceIds = [...updatingFeatureFaceIds, faceId];

    try {
      const updatedPerson = await updatePerson({
        id: faceGroup.person.id,
        personUpdateDto: { featureFaceId: faceId },
      });

      peopleWithFaces = peopleWithFaces.map((face) =>
        face.person?.id === updatedPerson.id ? { ...face, person: updatedPerson } : face,
      );
      eventManager.emit('PersonUpdate', updatedPerson);
      toastManager.primary($t('feature_photo_updated'));
    } catch (error) {
      handleError(error, $t('errors.unable_to_set_feature_photo'));
    } finally {
      updatingFeatureFaceIds = updatingFeatureFaceIds.filter((id) => id !== faceId);
    }
  };

  const handleBatchFacePicker = () => {
    const [firstFaceGroup] = selectedFaceGroups;
    if (!firstFaceGroup) {
      return;
    }

    editedFace = firstFaceGroup.face;
    editedFaceGroupId = undefined;
    editedFaceGroupIds = [...selectedFaceGroupIds];
    showSelectedFaces = true;
  };

  const deleteAssetFaceGroup = async (faceGroup: FaceGroup) => {
    try {
      const prompt =
        faceGroup.faces.length > 1
          ? $t('confirm_delete_faces_count', {
              values: { count: faceGroup.faces.length, name: faceGroup.person?.name ?? $t('face_unassigned') },
            })
          : $t('confirm_delete_face', { values: { name: faceGroup.person?.name ?? $t('face_unassigned') } });
      const isConfirmed = await modalManager.showDialog({
        prompt,
      });
      if (!isConfirmed) {
        return;
      }

      for (const face of faceGroup.faces) {
        await deleteFace({ id: face.id, assetFaceDeleteDto: { force: false } });
      }

      if (faceGroup.person) {
        eventManager.emit('PersonAssetDelete', { id: faceGroup.person.id, assetId });
      }

      const deletedFaceIds = new Set(faceGroup.faces.map((face) => face.id));
      peopleWithFaces = peopleWithFaces.filter((face) => !deletedFaceIds.has(face.id));
      expandedFaceGroupIds = expandedFaceGroupIds.filter((id) => id !== faceGroup.id && id !== faceGroup.parentId);

      await assetViewerManager.setAssetId(assetId);
    } catch (error) {
      handleError(error, $t('error_delete_face'));
    }
  };
</script>

<OnEvents {onPersonThumbnailReady} />

<svelte:document
  use:shortcut={{
    shortcut: { key: 'Escape' },
    onShortcut: () => {
      if (showSelectedFaces) {
        showSelectedFaces = false;
      } else {
        onClose();
      }
    },
  }}
/>

<section
  transition:fly={{ x: 360, duration: 100, easing: linear }}
  class="absolute top-0 h-full w-90 overflow-x-hidden p-2 dark:text-immich-dark-fg bg-light"
>
  <div class="flex place-items-center justify-between gap-2">
    <div class="flex items-center gap-2">
      <IconButton
        shape="round"
        color="secondary"
        variant="ghost"
        icon={mdiArrowLeftThin}
        aria-label={$t('back')}
        onclick={onClose}
      />
      <p class="flex text-lg text-immich-fg dark:text-immich-dark-fg">{$t('edit_faces')}</p>
    </div>
    {#if !isShowLoadingDone}
      <button
        type="button"
        class="justify-self-end rounded-lg p-2 hover:bg-immich-dark-primary hover:dark:bg-immich-dark-primary/50"
        onclick={() => handleEditFaces()}
      >
        {$t('done')}
      </button>
    {:else}
      <LoadingSpinner />
    {/if}
  </div>

  {#if selectedFaceGroupIds.length > 0}
    <div class="mx-4 mt-3 rounded-xl border border-immich-primary/30 bg-immich-primary/10 p-2 text-sm">
      <p class="font-medium text-immich-primary dark:text-immich-dark-primary">
        {$t('selected_faces_count', { values: { count: selectedFaceCount } })}
      </p>
      <div class="mt-2 flex gap-2">
        <button
          type="button"
          class="rounded-lg bg-immich-primary px-2 py-1 text-white hover:bg-immich-primary/80"
          onclick={handleBatchFacePicker}
        >
          {$t('assign_selected_faces')}
        </button>
        <button
          type="button"
          class="rounded-lg px-2 py-1 text-immich-fg hover:bg-gray-200 dark:text-immich-dark-fg hover:dark:bg-gray-700"
          onclick={clearSelectedFaceGroups}
        >
          {$t('clear')}
        </button>
      </div>
    </div>
  {/if}

  {#if expandedFaceGroupIds.length > 0}
    <div
      class="mx-4 mt-3 rounded-xl border border-gray-300/50 bg-gray-100 p-2 text-sm dark:border-gray-700 dark:bg-gray-800"
    >
      <p class="font-medium text-immich-fg dark:text-immich-dark-fg">{$t('editing_individual_faces')}</p>
      <button
        type="button"
        class="mt-2 rounded-lg px-2 py-1 text-immich-fg hover:bg-gray-200 dark:text-immich-dark-fg hover:dark:bg-gray-700"
        onclick={handleCollapseFaceGroups}
      >
        {$t('collapse')}
      </button>
    </div>
  {/if}

  <div class="px-4 py-4 text-sm">
    <div class="mt-4 flex flex-wrap gap-2">
      {#if isShowLoadingPeople}
        <div class="flex w-full justify-center">
          <LoadingSpinner />
        </div>
      {:else}
        {#each faceGroups as faceGroup, index (faceGroup.id)}
          {@const face = faceGroup.face}
          {@const personName = faceGroup.person ? faceGroup.person.name : $t('face_unassigned')}
          {@const isHighlighted = faceGroup.faces.some((face) => $boundingBoxesArray.some((b) => b.id === face.id))}
          {@const isSelected = isFaceGroupSelected(faceGroup)}
          <div
            class={`relative h-29 w-24 rounded-xl ${isSelected ? 'ring-2 ring-immich-primary ring-offset-2 ring-offset-white dark:ring-offset-black' : ''}`}
            data-testid="edit-face-card"
            data-face-count={faceGroup.faces.length}
            data-selected={isSelected}
          >
            <div
              role="button"
              tabindex={index}
              class="absolute start-0 top-0 h-22.5 w-22.5 cursor-default"
              onfocus={() => ($boundingBoxesArray = faceGroup.faces)}
              onmouseover={() => ($boundingBoxesArray = faceGroup.faces)}
              onmouseleave={() => ($boundingBoxesArray = [])}
            >
              <div class="relative">
                {#if selectedPersonToCreate[faceGroup.id]}
                  <ImageThumbnail
                    curve
                    shadow
                    highlighted={isHighlighted}
                    url={selectedPersonToCreate[faceGroup.id].featurePhoto}
                    altText={selectedPersonToCreate[faceGroup.id].name}
                    title={selectedPersonToCreate[faceGroup.id].name}
                    widthStyle={thumbnailWidth}
                    heightStyle={thumbnailWidth}
                  />
                {:else if selectedPersonToReassign[faceGroup.id]}
                  <ImageThumbnail
                    curve
                    shadow
                    highlighted={isHighlighted}
                    url={getPeopleThumbnailUrl(selectedPersonToReassign[faceGroup.id])}
                    altText={selectedPersonToReassign[faceGroup.id].name}
                    title={$getPersonNameWithHiddenValue(
                      selectedPersonToReassign[faceGroup.id].name,
                      selectedPersonToReassign[faceGroup.id]?.isHidden,
                    )}
                    widthStyle={thumbnailWidth}
                    heightStyle={thumbnailWidth}
                    hidden={selectedPersonToReassign[faceGroup.id].isHidden}
                  />
                {:else if faceGroup.person && !faceGroup.parentId}
                  <ImageThumbnail
                    curve
                    shadow
                    highlighted={isHighlighted}
                    url={getPeopleThumbnailUrl(faceGroup.person)}
                    altText={faceGroup.person.name}
                    title={$getPersonNameWithHiddenValue(faceGroup.person.name, faceGroup.person.isHidden)}
                    widthStyle={thumbnailWidth}
                    heightStyle={thumbnailWidth}
                    hidden={faceGroup.person.isHidden}
                  />
                {:else}
                  {#await zoomImageToBase64(face, assetId, assetType, assetViewerManager.imgRef)}
                    <ImageThumbnail
                      curve
                      shadow
                      highlighted={isHighlighted}
                      url={noThumbnailUrl}
                      altText={personName}
                      title={personName}
                      widthStyle="90px"
                      heightStyle="90px"
                    />
                  {:then data}
                    <ImageThumbnail
                      curve
                      shadow
                      highlighted={isHighlighted}
                      url={data === null ? noThumbnailUrl : data}
                      altText={personName}
                      title={personName}
                      widthStyle="90px"
                      heightStyle="90px"
                    />
                  {/await}
                {/if}
                {#if faceGroup.faces.length > 1}
                  <span
                    class="absolute bottom-1 end-1 rounded-full bg-black/70 px-1.5 py-0.5 text-xs font-semibold text-white"
                  >
                    {faceGroup.faces.length}
                  </span>
                {/if}
              </div>

              <p
                class="relative mt-1 truncate font-medium"
                title={selectedPersonToCreate[faceGroup.id]?.name ?? personName}
              >
                {#if selectedPersonToCreate[faceGroup.id]}
                  {selectedPersonToCreate[faceGroup.id].name}
                {:else if selectedPersonToReassign[faceGroup.id]?.id}
                  {selectedPersonToReassign[faceGroup.id]?.name}
                {:else}
                  <span class={personName === $t('face_unassigned') ? 'dark:text-gray-500' : ''}>{personName}</span>
                {/if}
              </p>

              <div class="absolute -end-[3px] -top-[3px] h-5 w-5 rounded-full">
                {#if selectedPersonToCreate[faceGroup.id] || selectedPersonToReassign[faceGroup.id]}
                  <button
                    type="button"
                    aria-label={$t('reset')}
                    class="absolute start-1/2 top-1/2 flex h-8 w-8 translate-x-[-50%] translate-y-[-50%] transform items-center justify-center rounded-full bg-white/95 text-black shadow-sm ring-1 ring-black/20 hover:bg-white focus-visible:outline-2 focus-visible:outline-immich-primary dark:bg-white/95 dark:text-black"
                    onclick={() => handleReset(faceGroup.id)}
                  >
                    <Icon icon={mdiRestart} aria-hidden size="20" />
                  </button>
                {:else if faceGroup.faces.length > 1}
                  <button
                    type="button"
                    aria-label={$t('expand')}
                    class="absolute start-1/2 top-1/2 flex h-8 w-8 translate-x-[-50%] translate-y-[-50%] transform items-center justify-center rounded-full bg-white/95 text-black shadow-sm ring-1 ring-black/20 hover:bg-white focus-visible:outline-2 focus-visible:outline-immich-primary dark:bg-white/95 dark:text-black"
                    onclick={() => handleExpandFaceGroup(faceGroup)}
                  >
                    <Icon icon={mdiChevronDown} aria-hidden size="20" />
                  </button>
                {:else}
                  <button
                    type="button"
                    aria-label={$t('select_new_face')}
                    class="absolute start-1/2 top-1/2 flex h-8 w-8 translate-x-[-50%] translate-y-[-50%] transform items-center justify-center rounded-full bg-white/95 text-black shadow-sm ring-1 ring-black/20 hover:bg-white focus-visible:outline-2 focus-visible:outline-immich-primary dark:bg-white/95 dark:text-black"
                    onclick={() => handleFacePicker(faceGroup)}
                  >
                    <Icon icon={mdiPencil} aria-hidden size="20" />
                  </button>
                {/if}
              </div>
              <div class="absolute end-8 -top-[3px] h-5 w-5 rounded-full">
                {#if isSelectableFaceGroup(faceGroup)}
                  <IconButton
                    shape="round"
                    color={isSelected ? 'primary' : 'secondary'}
                    variant={isSelected ? 'filled' : 'outline'}
                    icon={isSelected ? mdiCheckCircle : mdiCircleOutline}
                    aria-label={isSelected ? $t('selected') : $t('select')}
                    size="small"
                    class="absolute start-1/2 top-1/2 translate-x-[-50%] translate-y-[-50%] transform"
                    onclick={() => toggleFaceGroupSelection(faceGroup)}
                  />
                {:else if selectedPersonToCreate[faceGroup.id] || selectedPersonToReassign[faceGroup.id]}
                  <div
                    class="absolute start-1/2 top-1/2 flex h-7 w-7 translate-x-[-50%] translate-y-[-50%] transform items-center justify-center rounded-full bg-primary text-light shadow-sm"
                  >
                    <Icon icon={mdiAccountMultipleCheckOutline} aria-hidden size="20" />
                  </div>
                {/if}
              </div>
              <div class="absolute -start-[3px] top-[68px] h-5 w-5 rounded-full">
                <IconButton
                  shape="round"
                  color="danger"
                  icon={mdiTrashCan}
                  aria-label={$t('delete_face')}
                  size="small"
                  class="absolute start-1/2 top-1/2 translate-x-[-50%] translate-y-[-50%] transform"
                  onclick={() => deleteAssetFaceGroup(faceGroup)}
                />
              </div>
              {#if canSetFeatureFace(faceGroup)}
                <div class="absolute end-1 top-[68px] h-5 w-5 rounded-full">
                  <button
                    type="button"
                    aria-label={$t('set_as_featured_photo')}
                    title={$t('set_as_featured_photo')}
                    disabled={isUpdatingFeatureFace(faceGroup)}
                    class="absolute start-1/2 top-1/2 flex h-8 w-8 translate-x-[-50%] translate-y-[-50%] transform items-center justify-center rounded-full bg-white/95 text-black shadow-sm ring-1 ring-black/20 hover:bg-white disabled:cursor-wait disabled:opacity-70 focus-visible:outline-2 focus-visible:outline-immich-primary dark:bg-white/95 dark:text-black"
                    onclick={() => handleSetFeatureFace(faceGroup)}
                  >
                    {#if isUpdatingFeatureFace(faceGroup)}
                      <LoadingSpinner />
                    {:else}
                      <Icon icon={mdiFaceManProfile} aria-hidden size="20" />
                    {/if}
                  </button>
                </div>
              {/if}
            </div>
          </div>
        {/each}
      {/if}
    </div>
  </div>
</section>

{#if showSelectedFaces && editedFace}
  <AssignFaceSidePanel
    {editedFace}
    {assetId}
    {assetType}
    onClose={() => (showSelectedFaces = false)}
    onCreatePerson={handleCreatePerson}
    onReassign={handleReassignFace}
  />
{/if}
