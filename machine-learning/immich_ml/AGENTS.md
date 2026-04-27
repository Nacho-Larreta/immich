# immich_ml AGENTS

## Propósito

Código fuente principal del servicio de machine learning.

## Submódulos relevantes

- `models/`: manejo de modelos, carga/configuración/inferencia.
- `sessions/`: administración de sesiones/runtime de inferencia.

## Regla práctica

- Mantener contratos HTTP y payloads estables hacia `server`.
- Evitar mezclar concerns de serving, carga de modelo y reglas de negocio en el mismo punto.
- Si aparece lógica compleja nueva, preferir separarla en servicios/módulos explícitos antes que agrandar handlers existentes.
