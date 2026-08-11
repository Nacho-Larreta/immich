---
name: iterate-capture
description: Capturar tres o mas observaciones nuevas en una ronda durable del milestone Immich, crear o enlazar issues y validar el conteo antes de implementar.
---

# Iterate Capture

## Entrada

Recibir una lista de feedback nueva o continuar una ronda abierta. Resolver
paths y reglas con `../iterate/SKILL.md`.

## Procedimiento

1. No modificar código de producto.
2. Determinar el `FEATURE_DIR` y buscar el round abierto más reciente.
3. Si no existe, crear `FEATURE_DIR/iterate/round-N.md` usando el schema de
   abajo y crear `context.md` sólo si falta.
4. Preservar cada observación en `Original feedback` con las palabras del
   usuario. No fusionar observaciones que tengan resultados verificables
   distintos.
5. Asignar IDs `FB-001`, `FB-002`, ... contiguos dentro del round.
6. Crear o enlazar un issue canónico por defecto real siguiendo el protocolo
   de issue capture. Un mismo causal puede agrupar ejecución, no criterios de
   aceptación.
7. Completar descripción, severidad, aceptación observable y estado inicial.
8. Registrar decisiones de agrupación y dependencias en `Decisions Log`.
9. Recalcular `Summary` y ejecutar `validate_round.py`.
10. Informar conteo e IDs al usuario y pedir confirmación explícita antes de
    pasar a execute. El diagnóstico read-only puede continuar.

## Schema del round

```markdown
---
round: 1
feature: milestone-slug
status: open
created_at: 2026-08-10T22:34:29-03:00
updated_at: 2026-08-10T22:34:29-03:00
---

# Iteration Round 1

## Summary

- Total: 3
- Open: 3
- Needs clarification: 0
- In progress: 0
- Resolved: 0
- Failed: 0

## Items

### FB-001 — Título revelador

- Issue: `../issues/019-slug.md`
- Status: open
- Severity: critical
- Owner: —
- Blocked by: —
- Verification: —

#### Original feedback

Texto literal.

#### Description

Interpretación técnica mínima.

#### Clarification

—

#### Acceptance criteria

- [ ] Resultado observable.

#### History

- 2026-08-10T22:34:29-03:00 — Captured.

## Decisions Log

- 2026-08-10 — Decisión y motivo.
```

## Context schema

`context.md` contiene sólo decisiones que sobreviven rondas: alcance del
milestone, invariantes, restricciones de release y referencias a rounds. No
duplica los ítems ni su estado.
