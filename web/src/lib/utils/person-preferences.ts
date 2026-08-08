import type { PersonResponseDto } from '@immich/sdk';

type RecentPersonUsage = {
  count: number;
  lastSelectedAt: number;
};

const RECENT_PERSON_SELECTIONS_KEY = 'immich:recent-person-selections';
const MAX_RECENT_PEOPLE = 100;

const readRecentPeople = (): Record<string, RecentPersonUsage> => {
  if (typeof localStorage === 'undefined') {
    return {};
  }

  try {
    return JSON.parse(localStorage.getItem(RECENT_PERSON_SELECTIONS_KEY) ?? '{}');
  } catch {
    return {};
  }
};

const writeRecentPeople = (recentPeople: Record<string, RecentPersonUsage>) => {
  if (typeof localStorage === 'undefined') {
    return;
  }

  const trimmedPeople = Object.fromEntries(
    Object.entries(recentPeople)
      .sort(([, a], [, b]) => b.count - a.count || b.lastSelectedAt - a.lastSelectedAt)
      .slice(0, MAX_RECENT_PEOPLE),
  );

  localStorage.setItem(RECENT_PERSON_SELECTIONS_KEY, JSON.stringify(trimmedPeople));
};

export const rememberPersonSelection = (personId: string) => {
  const recentPeople = readRecentPeople();
  const current = recentPeople[personId] ?? { count: 0, lastSelectedAt: 0 };

  recentPeople[personId] = {
    count: current.count + 1,
    lastSelectedAt: Date.now(),
  };

  writeRecentPeople(recentPeople);
};

export const orderPeopleByPreference = (
  people: PersonResponseDto[],
  options: { selectedIds?: Set<string>; selectedFirst?: boolean } = {},
) => {
  const recentPeople = readRecentPeople();

  return people
    .map((person, index) => ({ person, index }))
    .sort((a, b) => {
      if (options.selectedFirst && options.selectedIds) {
        const selectedScore =
          Number(options.selectedIds.has(b.person.id)) - Number(options.selectedIds.has(a.person.id));
        if (selectedScore !== 0) {
          return selectedScore;
        }
      }

      const favoriteScore = Number(Boolean(b.person.isFavorite)) - Number(Boolean(a.person.isFavorite));
      if (favoriteScore !== 0) {
        return favoriteScore;
      }

      const aRecent = recentPeople[a.person.id];
      const bRecent = recentPeople[b.person.id];
      const recentScore = (bRecent?.count ?? 0) - (aRecent?.count ?? 0);
      if (recentScore !== 0) {
        return recentScore;
      }

      const lastSelectedScore = (bRecent?.lastSelectedAt ?? 0) - (aRecent?.lastSelectedAt ?? 0);
      if (lastSelectedScore !== 0) {
        return lastSelectedScore;
      }

      return a.index - b.index;
    })
    .map(({ person }) => person);
};
