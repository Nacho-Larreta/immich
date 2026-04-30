# Deployment AGENTS

## Propósito

Infraestructura declarativa basada en `terragrunt` / `opentofu`.

## Estado en este fork

- No parece ser la vía principal para desplegar en el NAS.
- Mantenerlo documentado, pero tratarlo como secundario salvo que después decidamos usar IaC para otra infraestructura.

## Regla práctica

- No asumir que esta carpeta representa el deploy real del NAS.
- Para el caso personal actual, el foco de deploy está más cerca de imágenes Docker + compose/runtime que de Terragrunt.
- El runbook operativo actual del NAS vive en `deployment/nas-custom-deploy.md`.
- No construir, publicar, pushear ni desplegar imágenes Docker para el NAS sin autorización explícita de Nacho en el turno actual. En tareas de deploy, dejar preparado el tag/comando y esperar confirmación antes de ejecutar.
