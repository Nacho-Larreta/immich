# Server AGENTS

## Propósito

Backend principal de Immich.

## Responsabilidades

- API REST para web/mobile/CLI.
- workers de background y cron jobs.
- coordinación con Postgres, Redis, file system y `machine-learning`.
- generación/consumo de contratos OpenAPI y SQL relacionados.

## Arquitectura

- Stack: TypeScript + NestJS + Express + Kysely.
- La documentación del proyecto la describe como hexagonal en forma laxa:
  - lógica en `src/services`
  - detalles de infraestructura en `src/repositories`
  - entrada HTTP en `src/controllers`
  - contratos públicos en `src/dtos`

## Relevancia para este fork

- Máxima prioridad.
- Cambios acá impactan directamente en deploy del NAS, integridad de datos y compatibilidad con `web`, `mobile` y `machine-learning`.

## Validación esperada

- `pnpm --filter immich run format`
- `pnpm --filter immich run lint`
- `pnpm --filter immich run check`
- `pnpm --filter immich run test`
- `pnpm --filter immich run build`

## Regla práctica

- No mezclar DTOs externos ni detalles de persistencia dentro de la lógica de negocio si se puede evitar.
- Si un cambio rompe compatibilidad de datos o contratos, documentarlo explícitamente antes de avanzar.
