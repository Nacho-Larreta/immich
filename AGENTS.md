# Immich Monorepo AGENTS

## Propósito

Este repo es un monorepo de producto. Desde acá se construyen:

- `server`: API, workers y jobs de background.
- `machine-learning`: servicio separado para inferencia.
- `web`: cliente web/admin.
- `mobile`: app Flutter compartida para iOS y Android.
- `cli`: cliente de línea de comandos.
- `open-api`: contratos y SDKs generados.

## Cómo pensar el sistema

- Arquitectura general: clientes REST contra `server`, con `postgres`, `redis`, file system y `machine-learning` como dependencias aguas abajo.
- `server` está documentado como una arquitectura hexagonal laxa:
  - `src/controllers`: entrada HTTP.
  - `src/dtos`: contratos públicos.
  - `src/services`: lógica de negocio.
  - `src/repositories`: adapters/implementaciones concretas.
- `mobile` tiene una arquitectura objetivo más limpia (`domain`, `infrastructure`, `presentation`), aunque la propia documentación admite que el estado real todavía no la sigue al 100%.

## Prioridades para este fork

- Alta prioridad: `server`, `machine-learning`, despliegue dockerizado y seguridad de datos del NAS.
- Prioridad media: `web`, sólo cuando haga falta acompañar cambios del backend.
- Prioridad baja por ahora: `mobile`, salvo que un cambio de backend exija ajustes en iOS.

## Reglas de edición

- Mantener compatibilidad con datos existentes por defecto.
- No tocar migraciones, storage layout ni volúmenes sin justificar impacto y rollback.
- Si una carpeta tiene su propio `AGENTS.md`, ese archivo manda sobre este documento para ese alcance.
- Para features nuevas, seguir el flujo workspace-level de `../.specify/` y `../specs/` antes de modificar código.
- No crear feature branches por defecto; este fork trabaja sobre `main` salvo instrucción explícita de Nacho.

## Tooling base

- Node/pnpm: workspace packages (`server`, `web`, `cli`, `docs`, `e2e`, `i18n`, `plugins`, `open-api/typescript-sdk`, `.github`).
- Flutter/Dart: `mobile`.
- Python/uv: `machine-learning`.
- Docker Compose: entornos dev/e2e/prod.
- `mise`: versionado de herramientas y tareas por módulo.

## Flujo recomendado antes de cambiar código

1. Instalar toolchain declarada por `mise`.
2. Verificar installs por stack.
3. Correr checks oficiales del repo y de CI.
4. Validar builds e imágenes base.
5. Recién después hacer cambios funcionales.
