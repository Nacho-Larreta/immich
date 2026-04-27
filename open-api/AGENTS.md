# OpenAPI AGENTS

## Propósito

Contratos y tooling de generación de clientes a partir del API del servidor.

## Importancia sistémica

- `server` publica DTOs y esquemas.
- `web`, `cli` y `mobile` consumen clientes generados a partir de estos contratos.

## Regla práctica

- Si cambia la API, esta carpeta es parte del cambio, no un detalle opcional.
- Mantener sincronía entre `server` y SDKs generados.
