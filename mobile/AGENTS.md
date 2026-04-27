# Mobile AGENTS

## Propósito

App Flutter compartida entre iOS y Android.

## Contexto de este fork

- Uso principal: iOS.
- No se asume publicación en App Store.
- Si hay cambios de app, el camino esperado es build local y distribución manual/ad-hoc.

## Arquitectura documentada

- Estado deseado: separación tipo MVVM/Clean-ish con `domain`, `infrastructure`, `presentation`, `providers`.
- Persistencia local: Isar.
- Estado global: Riverpod.
- La documentación del proyecto aclara que no todo el código actual sigue todavía esta arquitectura ideal.

## Relevancia para este fork

- Secundaria por ahora.
- Tocar sólo si cambios de backend/contratos obligan ajustes del cliente.

## Validación esperada

- `flutter pub get`
- generación de traducciones
- `flutter test`
- `dart analyze --fatal-infos`
- `dcm analyze lib --fatal-style --fatal-warnings`
