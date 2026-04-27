# Mobile Infrastructure AGENTS

## Propósito

Implementaciones concretas de persistencia y acceso a recursos externos para la app móvil.

## Regla de dependencia

- Implementa contratos definidos por la capa `domain`.
- No debe arrastrar concerns de UI.

## Qué debería vivir acá

- entities para base local
- repositories concretos
- helpers/utilidades específicas de infraestructura
