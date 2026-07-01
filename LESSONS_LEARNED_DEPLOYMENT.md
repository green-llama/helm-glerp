# Lessons Learned: GLERP Image and Helm Release

Fecha: 2026-06-29

## Contexto

Se actualizó `green-llama/frappe-gl` a `Frappe v16.24.3` con el ajuste en `redis_wrapper.py` para Dragonfly. Después hubo que reconstruir la imagen `ghcr.io/green-llama/glerp-image` y publicar un nuevo chart en `helm-glerp`.

Durante ese trabajo aparecieron varios problemas operativos que no conviene repetir.

## Qué salió mal

### 1. El token privado quedó expuesto en el history de la imagen

El flujo anterior de build usaba `APPS_JSON_BASE64` como `--build-arg` para pasar `apps.json` al `docker build`.

Eso tiene un problema serio: aunque el archivo final no quede dentro de la imagen runtime, el contenido del `build-arg` puede quedar visible en:

- `docker history --no-trunc`
- config de la imagen
- logs del build

Si `apps.json` contiene URLs con tokens embebidos para clonar apps privadas, esos tokens terminan filtrados en el artefacto.

### 2. Reempaquetar la imagen preservando xattrs/SELinux labels rompió el runtime en Kubernetes

Para sanear una imagen contaminada se hizo un repack del root filesystem.

La primera variante se reconstruyó preservando:

- `--xattrs`
- `--acls`
- `--selinux`

Eso produjo una imagen que arrancaba localmente, pero en el cluster el job `glerp-new-site` falló con:

```bash
bash: error while loading shared libraries: /lib/x86_64-linux-gnu/libc.so.6: cannot apply additional memory protection after relocation: Permission denied
```

La causa más probable fue que esos metadatos extendidos no eran apropiados para el runtime/nodo del cluster.

### 3. `release-chart.sh` dejaba el árbol sucio al volver a `main`

El flujo de release generaba `.tgz` nuevos en `.helm-repo`, pero al volver de `gh-pages` a `main` quedaban borrados locales de paquetes viejos ya versionados.

Resultado:

- `git status` quedaba sucio
- era fácil pensar que algo falló
- obligaba a restaurar archivos manualmente

## Qué se corrigió

### `scripts/deploy-image-and-chart.sh`

Ahora el script:

- usa `DOCKER_BUILDKIT=1`
- genera un Dockerfile temporal seguro
- monta `apps.json` como BuildKit secret:

```bash
--secret id=apps_json,src=/ruta/a/apps.json
```

- ya no usa `APPS_JSON_BASE64` como `build-arg`
- puede actualizar automáticamente:
  - `erpnext/values.yaml` -> `image.repository` e `image.tag`
  - `erpnext/Chart.yaml` -> patch version

### `scripts/release-chart.sh`

Ahora el script:

- permite cambios controlados en el chart cuando lo invoca el deploy script
- sigue rechazando cambios ajenos fuera del chart
- limpia `.helm-repo` al volver a `main`

## Procedimiento correcto la próxima vez

### Opción 1: flujo completo

Desde `helm-glerp`:

```bash
IMAGE_TAG=ghcr.io/green-llama/glerp-image:1.0.X \
APPS_JSON=/home/greenllama/frappe_docker_dev/development/apps.json \
GITHUB_TOKEN=... \
./scripts/deploy-image-and-chart.sh
```

Este flujo:

1. actualiza el tag en `values.yaml`
2. incrementa el patch version del chart
3. construye la imagen con BuildKit secret
4. hace push a GHCR
5. publica `main`
6. publica `gh-pages`

### Opción 2: solo construir y empujar imagen

```bash
IMAGE_TAG=ghcr.io/green-llama/glerp-image:1.0.X \
SKIP_RELEASE=true \
AUTO_UPDATE_CHART_IMAGE=false \
AUTO_BUMP_CHART_VERSION=false \
./scripts/deploy-image-and-chart.sh
```

## Checks obligatorios después del build

Antes de confiar en una imagen nueva:

### 1. Verificar que no haya secretos en el history

```bash
docker history --no-trunc ghcr.io/green-llama/glerp-image:TAG
```

No debe aparecer:

- `APPS_JSON_BASE64`
- tokens `ghp_...`
- URLs con `x-access-token`

### 2. Verificar arranque básico local

```bash
docker run --rm --entrypoint /bin/bash ghcr.io/green-llama/glerp-image:TAG -lc 'id; ldd --version | head -n 1'
```

### 3. Verificar manifest remoto

```bash
docker manifest inspect ghcr.io/green-llama/glerp-image:TAG
```

## Si vuelve a aparecer el error de `libc.so.6`

Si el cluster vuelve a mostrar:

```bash
cannot apply additional memory protection after relocation: Permission denied
```

revisar en este orden:

1. si la imagen fue repaquetada preservando xattrs/SELinux labels
2. si el nodo/pod runtime tiene restricciones adicionales
3. si hay diferencias entre la imagen local y la imagen realmente descargada por el cluster
4. si Rancher/Helm está usando el tag correcto

## Reglas que no se deben romper

- No hardcodear tokens en scripts.
- No pasar `apps.json` con credenciales como `--build-arg`.
- No publicar imágenes que expongan secretos en `docker history`.
- No reusar una imagen saneada hasta validar que arranca bien en runtime real.
- Si se reempaqueta una imagen, preferir no preservar `xattrs`, `ACLs` ni labels SELinux salvo que sea estrictamente necesario.

## Estado de referencia de este incidente

- `frappe-gl` publicado con `Frappe v16.24.3`
- imagen corregida: `ghcr.io/green-llama/glerp-image:1.0.3`
- chart publicado: `glerp-1.0.30`

