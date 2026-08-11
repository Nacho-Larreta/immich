---
name: iterate-clarify
description: Aclarar ambiguedades bloqueantes de una ronda iterate de Immich sin redisenar el feedback ni comenzar implementacion.
---

# Iterate Clarify

1. Leer `../iterate/SKILL.md`, el round activo y `context.md`.
2. Identificar sólo decisiones que cambien comportamiento, alcance o riesgo.
3. Resolver por evidencia local todo lo descubrible en código, logs o docs.
4. Formular como máximo cinco preguntas breves al usuario.
5. Marcar `needs-clarification` únicamente los ítems realmente bloqueados.
6. Registrar respuesta y decisión en `Clarification` e `History`.
7. Volver a `open` cuando el bloqueo se resuelva.
8. Recalcular `Summary` y validar el round.

No usar preguntas para delegar decisiones técnicas ordinarias. No ejecutar ni
modificar código de producto durante esta fase.
