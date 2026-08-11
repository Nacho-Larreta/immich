---
name: bugfix
description: Diagnosticar y corregir defectos en Immich con issue canonico, reproduccion RED, causal propia primero, cambio minimo, gates scoped y evidencia durable.
---

# Bugfix

## Contrato

1. Capturar el defecto en `WORKSPACE_ROOT/milestones/<milestone>/issues/` antes
   de cambiar producto. Usar `status: triage` para reportes nuevos.
2. Preservar evidencia: build/SHA, dispositivo, timestamp, pasos, log y mensaje
   exacto. No copiar secretos a trackers.
3. Reconstruir la secuencia causal desde logs y código propio antes de culpar
   framework, servidor, red o dispositivo.
4. Escribir un test RED en la frontera más baja que reproduzca el contrato roto.
5. Implementar el cambio mínimo que restaure el invariante. No ampliar política
   compartida para resolver un caso local sin consultar.
6. Cubrir éxito, error, retry/cancel y carrera relevante según el defecto.
7. Ejecutar sólo gates impactados más analyzer/lint/format y diff check.
8. Pedir revisión arquitectónica o de seguridad cuando cambie auth, transporte,
   persistencia, redirects, lifecycle o ownership de recursos.
9. Actualizar Root cause, Fix, evidencia y `fixed-in` sólo después del gate.
10. Para iOS físico, mantener issue abierto hasta el smoke de Nacho.

## Severidad

- `critical`: crash, pérdida de datos, brecha o flujo principal inutilizable.
- `major`: comportamiento incorrecto o UX rota con workaround parcial.
- `minor`: polish sin pérdida funcional.

## Disciplina de runner

No correr suites completas por reflejo. No pipear un runner cuando el exit code
sea parte de la evidencia. Si el entorno restringido invalida una primitiva
nativa, usar un control conocido y repetir fuera del sandbox antes de concluir.
