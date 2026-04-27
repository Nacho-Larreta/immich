# server/src AGENTS

## Propósito

Código fuente del backend.

## Mapa rápido

- `controllers/`: endpoints HTTP.
- `dtos/`: contratos de entrada/salida y base de OpenAPI.
- `services/`: lógica de negocio y orquestación.
- `repositories/`: adapters hacia DB, FS, Redis, ML y otros detalles.
- `workers/`: workers y selección de procesos (`api`, `microservices`).
- `queries/` y `schema/`: acceso estructurado a SQL/esquemas.
- `commands/` y `bin/`: utilidades/entrypoints.
- `utils/`, `middleware/`, `types/`, `cores/`, `maintenance/`, `emails/`: soporte transversal.

## Regla práctica

- Controladores finos, servicios con reglas de negocio, repositorios como boundary hacia detalles.
- Evitar lógica de negocio dispersa en controllers, queries o middleware.
