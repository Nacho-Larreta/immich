# Runbook De Deploy Custom En NAS

Runbook operativo privado para el deploy de Nacho en Synology NAS.

Esto no es documentacion upstream de Immich. Documenta el fork personal, los tags actuales, checks de seguridad y recuperacion.

## Estado Estable

NAS:

- Host: `192.168.68.75`
- Compose dir: `/volume1/docker/immich`
- Arquitectura: `linux/amd64`

Imagenes estables:

```yaml
services:
  immich-server:
    image: ghcr.io/nacho-larreta/immich-server:nas-v1-webfix-21751d858
    environment:
      IMMICH_HOST: 0.0.0.0

  immich-machine-learning:
    image: ghcr.io/nacho-larreta/immich-machine-learning:nas-v1-775de733a
```

Notas importantes:

- `IMMICH_HOST=0.0.0.0` es necesario en el NAS. Sin eso el server puede quedar escuchando solo en loopback dentro del contenedor.
- La DB fue migrada de Immich `2.5.6` a `2.7.5`. No volver a una imagen `2.5.6` sin restaurar tambien la DB compatible.
- Los assets no forman parte del backup DB. No borrar ni modificar `${UPLOAD_LOCATION}`.

## Backup Pre Deploy

Ejecutar desde el NAS:

```bash
cd /volume1/docker/immich

BACKUP_DIR="/volume1/docker/immich/backups/pre-custom-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

sudo cp docker-compose.yml "$BACKUP_DIR/docker-compose.yml"
sudo docker compose config > "$BACKUP_DIR/docker-compose-rendered.yml"
sudo docker compose ps > "$BACKUP_DIR/docker-compose-ps.txt"
sudo docker inspect immich_server immich_machine_learning immich_postgres immich_redis > "$BACKUP_DIR/docker-inspect.json"

sudo docker exec immich_postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z 9' > "$BACKUP_DIR/immich-db.dump"
sudo docker exec immich_postgres sh -c 'pg_dumpall -U "$POSTGRES_USER" --globals-only' > "$BACKUP_DIR/postgres-globals.sql"
sudo docker exec -i immich_postgres pg_restore --list < "$BACKUP_DIR/immich-db.dump" > "$BACKUP_DIR/immich-db-restore-list.txt"

ls -lh "$BACKUP_DIR"
head -20 "$BACKUP_DIR/immich-db-restore-list.txt"
```

Validacion esperada:

- `immich-db.dump` existe y tiene peso real.
- `immich-db-restore-list.txt` muestra un dump PostgreSQL custom format.
- No se copian fotos/videos familiares en este backup.

## Deploy

Preferir Docker Compose CLI sobre Synology Container Manager para despliegues repetibles.

Si cambia solo `immich-server`:

```bash
cd /volume1/docker/immich

sudo docker compose pull immich-server
sudo docker compose up -d --no-deps --force-recreate immich-server
sudo docker compose ps
```

Si cambian server y ML:

```bash
cd /volume1/docker/immich

sudo docker compose pull immich-server immich-machine-learning
sudo docker compose up -d immich-server immich-machine-learning
sudo docker compose ps
```

## Health Checks

```bash
curl -fsS http://127.0.0.1:2283/api/server/ping
curl -fsS http://127.0.0.1:2283/api/server/version

sudo docker logs --tail=120 immich_server
sudo docker logs --tail=120 immich_machine_learning
```

Esperado:

- `ping` responde `{"res":"pong"}`.
- `version` responde la version deployada.
- Logs del server muestran `Immich Server is listening`.
- Logs de ML muestran `Application startup complete`.

## Issues Conocidos Del Deploy

### API resetea la conexion

Sintoma:

- Logs muestran server escuchando en `[::1]:2283`.
- `curl http://127.0.0.1:2283/api/server/ping` falla o resetea.

Fix:

```yaml
immich-server:
  environment:
    IMMICH_HOST: 0.0.0.0
```

Recrear solo server:

```bash
sudo docker compose up -d --no-deps --force-recreate immich-server
```

### Web queda en splash

Sintoma:

- API responde.
- Browser queda en logo de Immich.
- Console muestra `Cannot read properties of undefined (reading 'env')`.

Causa:

- El HTML del build y un chunk SvelteKit referenciaban globals runtime distintos para `env`.

Fix estable:

- Usar `ghcr.io/nacho-larreta/immich-server:nas-v1-webfix-21751d858`.
- El fix aliasa `$env/dynamic/public` a un shim estatico del web app.

Validacion de imagen:

```bash
docker run --rm --platform linux/amd64 --entrypoint sh \
  ghcr.io/nacho-larreta/immich-server:nas-v1-webfix-21751d858 \
  -c "if grep -R 'globalThis.__sveltekit_.*.env' -n /build/www; then exit 1; else echo ok; fi"
```

### Synology Container Manager con `database is locked`

Sintoma:

- UI muestra `failed to initialize logging driver: database is locked`.
- Estado de Container Manager difiere del estado real por CLI.

Guia:

- No insistir con clicks repetidos.
- Inspeccionar verdad desde CLI:

```bash
cd /volume1/docker/immich
sudo docker compose ps
sudo docker ps -a --filter name=immich
```

- Si CLI esta sano, seguir operando por CLI.
- Reiniciar el paquete Container Manager solo despues de confirmar que Postgres/uploads no estan en operacion critica.

## Video Face Indexing

Ruta UI:

```text
Admin -> Configuracion -> Machine Learning -> Reconocimiento facial
```

Config relevante:

- Habilitar deteccion de caras en videos.
- Intervalo de frames de video.
- Maximo de frames de video.
- Lado largo del frame de video.
- Distancia para sugerencias de rostros.

Valores conservadores:

```text
Habilitar videos: ON
Intervalo: 5
Max frames: 30
Lado largo: 1440
Distancia de sugerencias: 1.0
```

Valores agresivos usados en prueba NAS:

```text
Habilitar videos: ON
Intervalo: 3
Max frames: 100
Lado largo: 1440
```

Notas:

- `Maximo de frames de video` es obligatorio. Vacio no significa sin limite.
- No existe modo ilimitado intencionalmente: videos largos podrian generar carga de CPU/IO sin techo.
- Los videos originales nunca se modifican. Los frames muestreados son cache derivado bajo thumbnails.

## Correr Analisis De Videos

Ruta UI:

```text
Admin -> Trabajos -> Deteccion de caras / Face Detection
```

Opciones:

- `Faltantes / Missing`: solo assets sin estado de caras. No alcanza para videos viejos ya marcados como procesados.
- `Actualizar / Refresh`: recomendado para activar video indexing sobre biblioteca existente. Refresca deteccion sin reset global.
- `Restablecer / Reset`: heavy. Remueve caras ML y frames derivados antes de reprocesar. Usar solo con backup DB reciente y razon clara.

Flujo recomendado:

1. Guardar config de Machine Learning.
2. Correr `Face Detection -> Refresh`.
3. Monitorear `Face Detection` y `Facial Recognition`.
4. Revisar `Personas` y `Sugerencias de rostros`.

## SQL Solo Lectura Util

Entrar a psql:

```bash
sudo docker exec -it immich_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Consultas:

```sql
select count(*) as video_face_frames from asset_face_frame;

select count(*) as video_faces
from asset_face af
join asset a on a.id = af."assetId"
where a.type = 'VIDEO';

select count(*) as unassigned_faces
from asset_face
where "personId" is null;
```

## Sugerencias De Rostros

El fork separa:

- `maxDistance`: umbral estricto de asignacion automatica.
- `suggestionMaxDistance`: umbral flexible para sugerencias manuales.

Flujo:

1. Header muestra `Sugerencias de rostros` cuando hay pendientes.
2. Abrir bandeja global.
3. Resolver cada sugerencia con `Si`, `No` o `Saltar`.
4. `No` guarda feedback negativo para no repetir ese par.
5. `Si` asigna la cara y registra historial de asignacion.

## Rollback

Rollback chico, solo tag server:

```bash
cd /volume1/docker/immich

# Editar docker-compose.yml a otro tag estable compatible con 2.7.5.
sudo docker compose pull immich-server
sudo docker compose up -d --no-deps --force-recreate immich-server
```

Rollback completo:

- Detener Immich.
- Restaurar compose pre-custom.
- Restaurar dump PostgreSQL compatible.
- No bajar version despues de migraciones DB sin restaurar DB compatible.

## Build Y Publish Desde Mac

Server:

```bash
cd /Users/ignaciolarreta/workspace_immich/immich

docker buildx build --platform linux/amd64 --push \
  -f server/Dockerfile \
  -t ghcr.io/nacho-larreta/immich-server:<tag> \
  .
```

Machine Learning CPU:

```bash
cd /Users/ignaciolarreta/workspace_immich/immich

docker buildx build --platform linux/amd64 --push \
  -f machine-learning/Dockerfile \
  --build-arg DEVICE=cpu \
  -t ghcr.io/nacho-larreta/immich-machine-learning:<tag> \
  machine-learning
```

Validar plataforma:

```bash
docker buildx imagetools inspect ghcr.io/nacho-larreta/immich-server:<tag>
docker buildx imagetools inspect ghcr.io/nacho-larreta/immich-machine-learning:<tag>
```

El NAS requiere `linux/amd64`.

## Reglas De Seguridad

- Nunca borrar `${UPLOAD_LOCATION}`.
- Nunca borrar `${DB_DATA_LOCATION}`.
- Nunca correr `docker compose down -v` en este stack.
- No volver a una version anterior de Immich despues de migraciones DB salvo restaurando DB compatible.
- Confirmar backup DB reciente antes de `Face Detection -> Reset`.
- Bajar concurrencia de jobs si el NAS se satura durante ML.
