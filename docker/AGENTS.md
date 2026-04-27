# Docker AGENTS

## Propósito

Compose files y recursos de contenedores para desarrollo y referencia de despliegue.

## Importante

- La propia documentación advierte que el compose de `main` puede no coincidir con el último release oficial.
- Para este fork, cualquier compose custom debe preservar volúmenes, base de datos y rutas de assets.

## Relevancia para este fork

- Esta carpeta es clave para validar builds locales e imágenes personalizadas.
- Cambios acá tienen riesgo alto sobre compatibilidad de despliegue.

## Regla práctica

- No renombrar volúmenes ni paths montados sin estrategia de migración/rollback.
- Priorizar cambios reversibles y fáciles de comparar contra el compose original.
