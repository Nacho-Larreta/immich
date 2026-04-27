# CLI AGENTS

## Propósito

Cliente de línea de comandos para interactuar con una instancia de Immich, especialmente para cargas masivas y automatización.

## Dependencias relevantes

- Depende del SDK TypeScript generado en `open-api/typescript-sdk`.
- Su build requiere que el contrato OpenAPI/SDK esté alineado con `server`.

## Señales de arquitectura

- Stack: TypeScript + Vite.
- Es un cliente liviano; no meter lógica de negocio del servidor acá.

## Comandos útiles

- `pnpm install --filter @immich/cli --frozen-lockfile`
- `pnpm --filter @immich/cli run lint`
- `pnpm --filter @immich/cli run check`
- `pnpm --filter @immich/cli run test`
- `pnpm --filter @immich/cli run build`
