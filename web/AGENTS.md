# Web AGENTS

## Propósito

Cliente web/admin de Immich.

## Arquitectura

- Stack: TypeScript + SvelteKit + Tailwind.
- En producción se compila como SPA y se distribuye junto al `server`.
- Consume el SDK TypeScript generado desde `open-api/typescript-sdk`.

## Relevancia para este fork

- Secundaria respecto a `server` y `machine-learning`, pero puede necesitar ajustes si cambian contratos o flujos administrativos.

## Validación esperada

- `pnpm --filter immich-web run format`
- `pnpm --filter immich-web run lint`
- `pnpm --filter immich-web run check:svelte`
- `pnpm --filter immich-web run check:typescript`
- `pnpm --filter immich-web run test`
- `pnpm --filter immich-web run build`
