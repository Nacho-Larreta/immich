# mobile/lib AGENTS

## Propósito

Código principal de la app Flutter.

## Mapa rápido

- `domain/`: reglas de negocio y contratos.
- `infrastructure/`: implementaciones concretas y acceso a persistencia/externalidades.
- `presentation/`, `pages/`, `widgets/`: UI y composición visual.
- `providers/`: wiring de Riverpod.
- `routing/`: navegación y guards.
- `platform/`: puentes nativos.
- `utils/`, `extensions/`, `constants/`, `theme/`: soporte transversal.

## Regla práctica

- Evitar saltarse capas cuando la arquitectura objetivo ya existe.
- Preferir que la UI dependa de providers/services y no de detalles concretos de repositorios o DTOs externos.
