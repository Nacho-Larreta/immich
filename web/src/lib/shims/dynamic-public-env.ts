// @immich/ui imports SvelteKit's dynamic public env only as a hostname fallback.
// Alias it to a static module so the packaged UI runtime cannot reference a
// different SvelteKit global than the consuming Immich web app.
export const env = {
  ...import.meta.env,
  PUBLIC_IMMICH_HOSTNAME: import.meta.env.PUBLIC_IMMICH_HOSTNAME ?? '',
};
