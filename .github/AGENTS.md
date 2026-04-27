# .github AGENTS

## Propósito

Esta carpeta contiene automatizaciones de CI/CD, templates y reglas de higiene del repo.

## Qué vive acá

- `workflows/`: definición de jobs oficiales para lint, tests, Docker builds, mobile y docs.
- `package.json`: formatting de archivos de `.github`.
- templates y metadata de PR/issues.

## Relevancia para este fork

- La fuente de verdad para saber qué valida oficialmente el proyecto está en estos workflows.
- Antes de inventar comandos, revisar acá qué corre CI para cada subproyecto.

## Regla práctica

- Tratar los workflows como contratos operativos.
- Evitar cambios innecesarios acá mientras el objetivo sea customizar el producto para uso personal y no rehacer el pipeline.
