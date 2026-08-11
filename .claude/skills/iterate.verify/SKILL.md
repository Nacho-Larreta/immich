---
name: iterate-verify
description: Verificar de forma independiente una ronda iterate de Immich con evidencia scoped y smoke fisico cuando toca iOS, antes de resolver items o liberar TestFlight.
---

# Iterate Verify

1. Leer `../iterate/SKILL.md`, round, context, issues y diff real.
2. Verificar cada criterio de aceptación contra código y evidencia, no contra
   el resumen del implementador.
3. Repetir los gates scoped exactos. Registrar comando, conteo y resultado.
4. Para seguridad o sesión, realizar revisión adversarial de fail-closed,
   identidad, lifecycle y carreras.
5. Para UI iOS, preparar una lista física breve con estado inicial, acción y
   resultado esperado. Nacho ejecuta el smoke en el dispositivo.
6. Escribir evidencia concreta en `Verification` e `History`.
7. Marcar `resolved` sólo si todos sus criterios pasaron. Usar `failed` si el
   defecto se reproduce todavía.
8. Recalcular `Summary`, validar el round y actualizar el issue relacionado.

Una build o suite verde no reemplaza el smoke físico exigido para TestFlight.
