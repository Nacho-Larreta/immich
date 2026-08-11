---
name: iterate-status
description: Reportar el estado verificable de una ronda iterate de Immich desde sus archivos canonicos, sin inferir progreso desde el chat o agentes.
---

# Iterate Status

1. Resolver paths con `../iterate/SKILL.md`.
2. Leer el round activo, `context.md`, issues enlazados y estado Git relevante.
3. Ejecutar `validate_round.py` antes de contar.
4. Reportar primero el resultado: total, abiertos, bloqueados, en progreso,
   resueltos verificados y fallidos.
5. Para cada ítem no resuelto indicar owner, bloqueo concreto y siguiente gate.
6. Distinguir implementación reportada, verificación automática y aceptación
   física/manual.
7. No modificar estados salvo que haya evidencia nueva verificable.
