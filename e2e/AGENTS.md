# E2E AGENTS

## Propósito

Tests end-to-end y utilidades de integración para validar flujos completos del producto.

## Dependencias relevantes

- Usa Docker Compose para levantar dependencias y servicios.
- Usa `@immich/e2e-auth-server` para escenarios de autenticación.

## Regla práctica

- Es la capa más cercana a validar que cambios en `server`, `web` o `cli` no rompen el flujo completo.
- Si tocamos backend o auth, estos tests pesan más que los tests unitarios aislados.
