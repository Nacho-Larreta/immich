<script lang="ts">
  import { focusOutside } from '$lib/actions/focus-outside';
  import ActionMenuItem from '$lib/components/ActionMenuItem.svelte';
  import ButtonContextMenu from '$lib/components/shared-components/context-menu/ButtonContextMenu.svelte';
  import { Route } from '$lib/route';
  import { getPersonActions } from '$lib/services/person.service';
  import { getPeopleThumbnailUrl } from '$lib/utils';
  import { type PersonResponseDto } from '@immich/sdk';
  import { Icon } from '@immich/ui';
  import {
    mdiAccountMultipleCheckOutline,
    mdiDotsVertical,
    mdiEyeOffOutline,
    mdiFaceRecognition,
    mdiHeart,
    mdiHeartMinusOutline,
    mdiHeartOutline,
  } from '@mdi/js';
  import { t } from 'svelte-i18n';
  import ImageThumbnail from '$lib/components/assets/thumbnail/ImageThumbnail.svelte';
  import MenuOption from '$lib/components/shared-components/context-menu/MenuOption.svelte';

  type Props = {
    person: PersonResponseDto;
    onMergePeople: () => void;
    onManageReferences: () => void;
    onHidePerson: () => void;
    onToggleFavorite: () => void;
  };

  let { person, onMergePeople, onManageReferences, onHidePerson, onToggleFavorite }: Props = $props();

  let showVerticalDots = $state(false);

  const { SetDateOfBirth } = $derived(getPersonActions($t, person));

  const handleToggleFavoriteClick = (event: MouseEvent) => {
    event.preventDefault();
    event.stopPropagation();
    onToggleFavorite();
  };
</script>

<div
  id="people-card"
  class="relative"
  onmouseenter={() => (showVerticalDots = true)}
  onmouseleave={() => (showVerticalDots = false)}
  role="group"
  use:focusOutside={{ onFocusOut: () => (showVerticalDots = false) }}
>
  <a
    href={Route.viewPerson(person, { previousRoute: Route.people() })}
    draggable="false"
    onfocus={() => (showVerticalDots = true)}
  >
    <div class="w-full h-full rounded-xl brightness-95 filter">
      <ImageThumbnail
        shadow
        url={getPeopleThumbnailUrl(person)}
        altText={person.name}
        title={person.name}
        widthStyle="100%"
        circle
        preload={false}
      />
    </div>
  </a>

  <button
    type="button"
    class={`absolute start-2 top-2 z-1 flex h-9 w-9 items-center justify-center rounded-full shadow-sm ring-1 ring-black/20 transition-all focus-visible:outline-2 focus-visible:outline-immich-primary ${
      person.isFavorite
        ? 'bg-white/95 text-rose-500 hover:bg-white'
        : 'bg-black/45 text-white hover:bg-white/95 hover:text-rose-500'
    }`}
    aria-label={person.isFavorite ? $t('unfavorite') : $t('to_favorite')}
    aria-pressed={person.isFavorite}
    title={person.isFavorite ? $t('unfavorite') : $t('to_favorite')}
    onclick={handleToggleFavoriteClick}
  >
    <Icon icon={person.isFavorite ? mdiHeart : mdiHeartOutline} size="22" aria-hidden />
  </button>

  {#if showVerticalDots}
    <div class="absolute top-2 end-2 z-1">
      <ButtonContextMenu
        buttonClass="icon-white-drop-shadow"
        color="secondary"
        size="medium"
        variant="filled"
        icon={mdiDotsVertical}
        title={$t('show_person_options')}
      >
        <MenuOption onClick={onHidePerson} icon={mdiEyeOffOutline} text={$t('hide_person')} />
        <ActionMenuItem action={SetDateOfBirth} />
        <MenuOption onClick={onManageReferences} icon={mdiFaceRecognition} text={$t('manage_face_references')} />
        <MenuOption onClick={onMergePeople} icon={mdiAccountMultipleCheckOutline} text={$t('merge_people')} />
        <MenuOption
          onClick={onToggleFavorite}
          icon={person.isFavorite ? mdiHeartMinusOutline : mdiHeartOutline}
          text={person.isFavorite ? $t('unfavorite') : $t('to_favorite')}
        />
      </ButtonContextMenu>
    </div>
  {/if}
</div>
