# web/src AGENTS

## Propósito

Código fuente del cliente web.

## Mapa rápido

- `routes/`: páginas/rutas de SvelteKit.
- `lib/`: componentes, stores, helpers y lógica compartida del cliente.
- `params/`: validación/parseo de params.
- `service-worker/`: comportamiento offline/cache específico.
- `test-data/`: fixtures de test.

## Regla práctica

- Mantener la UI delgada y empujar reglas complejas a utilidades/stores claros.
- Si un cambio depende de backend, confirmar primero que el contrato OpenAPI/SDK quedó alineado.
