# Machine Learning AGENTS

## Propósito

Servicio Python separado para inferencia de:

- embeddings CLIP
- reconocimiento facial
- OCR y otras tareas relacionadas a features inteligentes

## Arquitectura

- Stack: Python + FastAPI.
- Runtime y dependencias manejados con `uv`.
- Modelos ONNX descargados/cargados bajo demanda y reutilizados por caché.
- Este servicio existe separado porque sus dependencias y requisitos de hardware son distintos al backend principal.

## Relevancia para este fork

- Es uno de los focos principales de personalización.
- Cualquier cambio debe cuidar compatibilidad de API con `server`.

## Validación esperada

- `uv sync --extra cpu`
- `uv run ruff check immich_ml`
- `uv run ruff format --check immich_ml`
- `uv run mypy --strict immich_ml/`
- `uv run pytest --cov=immich_ml --cov-report term-missing`
