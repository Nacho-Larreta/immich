<script lang="ts">
  import { shortcut } from '$lib/actions/shortcut';
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
    type AssetFaceResponseDto,
    type PersonResponseDto,
  } from '@immich/sdk';
  import { Icon, IconButton, LoadingSpinner, modalManager, toastManager } from '@immich/ui';
  import { mdiAccountOff, mdiArrowLeftThin, mdiPencil, mdiRestart, mdiTrashCan } from '@mdi/js';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';
  import { linear } from 'svelte/easing';
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
  };

  let { assetId, assetType, onClose, onRefresh }: Props = $props();

  // keep track of the changes
  let peopleToCreate: string[] = [];
  let assetFaceGenerated: string[] = [];

  // faces
  let peopleWithFaces: AssetFaceResponseDto[] = $state([]);
  let selectedPersonToReassign: Record<string, PersonResponseDto> = $state({});
  let selectedPersonToCreate: Record<string, string> = $state({});
  let editedFace: AssetFaceResponseDto | undefined = $state();
  let editedFaceGroupId: string | undefined = $state();

  // loading spinners
  let isShowLoadingDone = $state(false);
  let isShowLoadingPeople = $state(false);

  // search people
  let showSelectedFaces = $state(false);

  // timers
  let loaderLoadingDoneTimeout: ReturnType<typeof setTimeout>;
  let automaticRefreshTimeout: ReturnType<typeof setTimeout>;

  const thumbnailWidth = '90px';

  const faceGroups = $derived.by((): FaceGroup[] => {
    const groups = new Map<string, FaceGroup>();

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
    if (
      isEqual(assetFaceGenerated, peopleToCreate) &&
      loaderLoadingDoneTimeout &&
      automaticRefreshTimeout &&
      Object.keys(selectedPersonToCreate).length === peopleToCreate.length
    ) {
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
  };

  const handleEditFaces = async () => {
    loaderLoadingDoneTimeout = setTimeout(() => (isShowLoadingDone = true), timeBeforeShowLoadingSpinner);
    const numberOfChanges = Object.keys(selectedPersonToCreate).length + Object.keys(selectedPersonToReassign).length;

    if (numberOfChanges > 0) {
      try {
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
            const data = await createPerson({ personCreateDto: {} });
            peopleToCreate.push(data.id);
            for (const face of faceGroup.faces) {
              await reassignFacesById({
                id: data.id,
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

  const handleCreatePerson = (newFeaturePhoto: string | null) => {
    if (newFeaturePhoto && editedFaceGroupId) {
      selectedPersonToCreate[editedFaceGroupId] = newFeaturePhoto;
    }
    showSelectedFaces = false;
  };

  const handleReassignFace = (person: PersonResponseDto | null) => {
    if (person && editedFaceGroupId) {
      selectedPersonToReassign[editedFaceGroupId] = person;
    }
    showSelectedFaces = false;
  };

  const handleFacePicker = (faceGroup: FaceGroup) => {
    editedFace = faceGroup.face;
    editedFaceGroupId = faceGroup.id;
    showSelectedFaces = true;
  };

  const deleteAssetFaceGroup = async (faceGroup: FaceGroup) => {
    try {
      const isConfirmed = await modalManager.showDialog({
        prompt: $t('confirm_delete_face', { values: { name: faceGroup.person?.name ?? $t('face_unassigned') } }),
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
          <div class="relative h-29 w-24" data-testid="edit-face-card" data-face-count={faceGroup.faces.length}>
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
                    url={selectedPersonToCreate[faceGroup.id]}
                    altText={$t('new_person')}
                    title={$t('new_person')}
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
                {:else if faceGroup.person}
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
                      url="/src/lib/assets/no-thumbnail.png"
                      altText={$t('face_unassigned')}
                      title={$t('face_unassigned')}
                      widthStyle="90px"
                      heightStyle="90px"
                    />
                  {:then data}
                    <ImageThumbnail
                      curve
                      shadow
                      highlighted={isHighlighted}
                      url={data === null ? '/src/lib/assets/no-thumbnail.png' : data}
                      altText={$t('face_unassigned')}
                      title={$t('face_unassigned')}
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

              {#if !selectedPersonToCreate[faceGroup.id]}
                <p class="relative mt-1 truncate font-medium" title={personName}>
                  {#if selectedPersonToReassign[faceGroup.id]?.id}
                    {selectedPersonToReassign[faceGroup.id]?.name}
                  {:else}
                    <span class={personName === $t('face_unassigned') ? 'dark:text-gray-500' : ''}>{personName}</span>
                  {/if}
                </p>
              {/if}

              <div class="absolute -end-[3px] -top-[3px] h-5 w-5 rounded-full">
                {#if selectedPersonToCreate[faceGroup.id] || selectedPersonToReassign[faceGroup.id]}
                  <IconButton
                    shape="round"
                    variant="ghost"
                    color="primary"
                    icon={mdiRestart}
                    aria-label={$t('reset')}
                    size="small"
                    class="absolute start-1/2 top-1/2 translate-x-[-50%] translate-y-[-50%] transform"
                    onclick={() => handleReset(faceGroup.id)}
                  />
                {:else}
                  <IconButton
                    shape="round"
                    color="primary"
                    icon={mdiPencil}
                    aria-label={$t('select_new_face')}
                    size="small"
                    class="absolute start-1/2 top-1/2 translate-x-[-50%] translate-y-[-50%] transform"
                    onclick={() => handleFacePicker(faceGroup)}
                  />
                {/if}
              </div>
              <div class="absolute end-8 -top-[3px] h-5 w-5 rounded-full">
                {#if !selectedPersonToCreate[faceGroup.id] && !selectedPersonToReassign[faceGroup.id] && !faceGroup.person}
                  <div
                    class="flex place-content-center place-items-center rounded-full bg-[#d3d3d3] p-1 transition-all absolute start-1/2 top-1/2 translate-x-[-50%] translate-y-[-50%] transform"
                  >
                    <Icon color="primary" icon={mdiAccountOff} aria-hidden size="24" />
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
