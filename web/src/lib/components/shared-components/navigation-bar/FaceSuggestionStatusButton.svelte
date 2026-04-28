<script lang="ts">
  import { afterNavigate } from '$app/navigation';
  import { page } from '$app/state';
  import { Route } from '$lib/route';
  import { getFaceSuggestionSummary } from '@immich/sdk';
  import { Icon } from '@immich/ui';
  import { mdiFaceRecognition } from '@mdi/js';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';

  let pendingPeople = $state(0);
  let hasMorePeople = $state(false);
  let isLoading = $state(false);

  const shouldCheckSuggestions = $derived(
    !page.url.pathname.includes('/admin') && page.url.pathname !== Route.faceSuggestions(),
  );
  const label = $derived(
    hasMorePeople
      ? $t('face_suggestions_pending_count_more', { values: { count: pendingPeople } })
      : $t('face_suggestions_pending_count', { values: { count: pendingPeople } }),
  );

  const refresh = async () => {
    if (!shouldCheckSuggestions || isLoading) {
      return;
    }

    isLoading = true;
    try {
      const summary = await getFaceSuggestionSummary({ size: 1, peopleLimit: 100 });
      pendingPeople = summary.pendingPeople;
      hasMorePeople = summary.hasMorePeople;
    } catch (error) {
      pendingPeople = 0;
      hasMorePeople = false;
      console.debug('Unable to load face suggestion summary', error);
    } finally {
      isLoading = false;
    }
  };

  onMount(() => {
    void refresh();
  });

  afterNavigate(() => {
    void refresh();
  });
</script>

{#if shouldCheckSuggestions && pendingPeople > 0}
  <a
    data-sveltekit-preload-data="hover"
    href={Route.faceSuggestions()}
    class="flex min-h-9 items-center gap-2 rounded-full border border-immich-primary/30 bg-immich-primary/10 px-3 text-sm font-semibold text-primary transition-colors hover:bg-immich-primary/20 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-immich-primary dark:border-immich-dark-primary/40 dark:bg-immich-dark-primary/20 dark:text-immich-dark-primary dark:hover:bg-immich-dark-primary/30"
    aria-label={label}
    title={label}
  >
    <Icon icon={mdiFaceRecognition} size="20" aria-hidden />
    <span class="hidden whitespace-nowrap xl:inline">{$t('face_suggestions_pending')}</span>
    <span
      class="flex h-5 min-w-5 items-center justify-center rounded-full bg-primary px-1.5 text-[11px] font-bold text-light dark:bg-immich-dark-primary dark:text-black"
    >
      {pendingPeople}{hasMorePeople ? '+' : ''}
    </span>
  </a>
{/if}
