---
name: iterate
description: Gestionar rondas durables de tres o mas observaciones, feedback iterativo, war rooms y reanudaciones sin perder items entre sesiones o agentes. Usar para capture, clarify, execute, verify y status de feedback en el workspace Immich.
---

# Iterate

Orquestar feedback grande usando archivos canónicos compartidos. El chat, los
planes temporales y los agentes no son fuente de verdad.

## Resolver paths

1. Resolver `WORKTREE_ROOT` con `git rev-parse --show-toplevel`.
2. Resolver `WORKSPACE_ROOT` como el padre de `WORKTREE_ROOT`.
3. Leer `WORKTREE_ROOT/AGENTS.md` y las instrucciones anidadas aplicables.
4. Resolver el milestone desde el contexto activo. En este workspace:
   `FEATURE_DIR=$WORKSPACE_ROOT/milestones/<milestone>`.
5. Leer completo este archivo y el skill de fase requerido:
   `iterate.capture`, `iterate.clarify`, `iterate.execute`, `iterate.verify` o
   `iterate.status`.
6. Para defectos, leer también `../bugfix/SKILL.md` y
   `~/.claude/protocols/issue-capture.md` si existe.

Si el milestone no puede inferirse, hacer una sola pregunta. No crear trackers,
schemas o ubicaciones alternativas.

## Fuentes de verdad

| Información | Fuente canónica |
|---|---|
| Feedback, estado, evidencia e historial | `FEATURE_DIR/iterate/round-N.md` |
| Decisiones acumuladas | `FEATURE_DIR/iterate/context.md` |
| Defectos | `FEATURE_DIR/issues/` |
| Código y tests | Git y el worktree propietario |
| Cursor entre sesiones | Checkpoint que referencia la ronda activa |

## Fases

| Pedido | Skill |
|---|---|
| Lista nueva o `$iterate` | `iterate.capture` |
| Aclarar ítems | `iterate.clarify` |
| Implementar ítems confirmados | `iterate.execute` |
| Verificar implementación | `iterate.verify` |
| Consultar estado | `iterate.status` |

## Reglas no negociables

- Capturar tres o más ítems antes de modificar código de producto.
- Preservar el texto original del usuario sin reinterpretarlo.
- Asignar todos los IDs antes de delegar.
- Un worktree dirty admite un único mutador; los demás agentes son read-only.
- Ejecutar gates scoped; no correr suites completas por reflejo.
- Para UI física iOS, la aceptación manual en dispositivo es obligatoria.
- No marcar `resolved` sin evidencia concreta en `Verification`.
- No commitear ni pushear sin la autorización aplicable.

## Estados

Usar únicamente `open`, `needs-clarification`, `in-progress`, `resolved` y
`failed`. Una ronda cierra sólo cuando todos sus ítems están `resolved` y tienen
evidencia de verificación.

## Validación

Después de cada edición del round ejecutar:

```bash
python3 "$WORKTREE_ROOT/.claude/skills/iterate/scripts/validate_round.py" \
  "$ROUND_FILE"
```

El validador es obligatorio antes de reportar conteos, pedir confirmación,
crear un checkpoint o cerrar la ronda.
