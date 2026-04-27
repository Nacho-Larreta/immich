# TypeScript SDK AGENTS

## Propósito

SDK TypeScript autogenerado para consumir la API de Immich.

## Consumidores principales

- `web`
- `cli`
- tests/e2e que integran contra la API

## Regla práctica

- No meter lógica manual de negocio acá.
- Tratarlo como artefacto generado y validarlo cuando cambien DTOs/endpoints del servidor.
