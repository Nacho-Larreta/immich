---
name: iterate-execute
description: Ejecutar items confirmados de una ronda iterate de Immich con ownership unico, RED primero y gates scoped, preservando trackers y trabajo ajeno.
---

# Iterate Execute

## Precondiciones

- Leer `../iterate/SKILL.md`, `../bugfix/SKILL.md`, el round y `context.md`.
- Confirmar en `History` autorización explícita o continuidad de un smoke/fix
  activo ya autorizado; no pedir una segunda aprobación para esa continuidad.
- El round debe validar y no tener ítems ambiguos seleccionados.

## Procedimiento

1. Construir un DAG por causal, archivos y dependencias.
2. Registrar una tabla de lanes en `Decisions Log` con ítems, write set,
   `blockedBy`, worktree y owner.
3. Mantener un solo mutador por worktree. Agentes secundarios son read-only
   salvo worktrees dedicados autorizados.
4. Marcar cada ítem activo `in-progress` antes de escribir producto.
5. Reproducir el defecto con un test RED o evidencia determinística equivalente.
6. Implementar el cambio mínimo en la frontera causal correcta.
7. Ejecutar tests scoped, analyzer/lint/format del área tocada y diff check.
8. Actualizar `History` con RED, fix y gates. Dejar `Verification: —` hasta el
   gate independiente.
9. Nunca ocultar un fallo runner ni sustituirlo por una suite distinta.

## Brief de delegación

Incluir `NUEVA ASIGNACIÓN`, SHA, worktree absoluto, texto/IDs, write set,
paths prohibidos, dependencias, criterio de cierre, gates scoped, prohibición de
editar trackers y de commit/push, y recordatorio de trabajo compartido.
