#!/usr/bin/env bash
set -euo pipefail

<<<<<<< HEAD
# One-shot helper to build/push the GLerp image and release the Helm chart.
# Requirements:
#   - docker login ghcr.io already done (token stored in ~/.docker/config.json)
#   - git credentials set for pushing to origin (main and gh-pages)
#   - helm installed locally
#
# Environment overrides (optional):
#   IMAGE_TAG (default: ghcr.io/green-llama/glerp-image:dev)
#   FRAPPE_PATH (default: https://github.com/green-llama/frappe-gl)
#   FRAPPE_BRANCH (default: develop)
#   APPS_JSON (default: /home/greenllama/frappe_docker_dev/development/apps.json)
#   HELM_ROOT (default: /home/greenllama/helm-glerp)
=======
# One-shot helper to build & push the GLerp image and release the Helm chart.
# Requirements:
#   - docker login ghcr.io (token stored in ~/.docker/config.json)
#   - git credentials configured for pushing to origin (main and gh-pages)
#   - helm installed locally
#
# Environment overrides:
#   IMAGE_TAG      (default: ghcr.io/green-llama/glerp-image:dev)
#   FRAPPE_PATH    (default: https://github.com/green-llama/frappe-gl)
#   FRAPPE_BRANCH  (default: develop)
#   APPS_JSON      (default: /home/greenllama/frappe_docker_dev/development/apps.json)
#   HELM_ROOT      (default: /home/greenllama/helm-glerp)
#   BUILD_CONTEXT  (default: /home/greenllama/frappe_docker_dev)
#   DOCKERFILE     (default: images/layered/Containerfile, relative to BUILD_CONTEXT)
>>>>>>> main

IMAGE_TAG="${IMAGE_TAG:-ghcr.io/green-llama/glerp-image:dev}"
FRAPPE_PATH="${FRAPPE_PATH:-https://github.com/green-llama/frappe-gl}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"
APPS_JSON="${APPS_JSON:-/home/greenllama/frappe_docker_dev/development/apps.json}"
HELM_ROOT="${HELM_ROOT:-/home/greenllama/helm-glerp}"
<<<<<<< HEAD

cd "$(dirname "$0")/.."

build_image() {
  echo "=== Building image ${IMAGE_TAG} with apps from ${APPS_JSON} ==="
  if [[ ! -f "${APPS_JSON}" ]]; then
    echo "apps.json not found at ${APPS_JSON}" >&2
    exit 1
  }
  APPS_JSON_BASE64=$(base64 -w0 "${APPS_JSON}")
  docker build --progress=plain \
    --file images/layered/Containerfile \
=======
BUILD_CONTEXT="${BUILD_CONTEXT:-/home/greenllama/frappe_docker_dev}"
DOCKERFILE="${DOCKERFILE:-images/layered/Containerfile}"

build_image() {
  echo "=== Building image ${IMAGE_TAG} ==="
  if [[ ! -f "${APPS_JSON}" ]]; then
    echo "apps.json not found at ${APPS_JSON}" >&2
    exit 1
  fi
  APPS_JSON_BASE64=$(base64 -w0 "${APPS_JSON}")
  if [[ -z "${APPS_JSON_BASE64}" ]]; then
    echo "APPS_JSON_BASE64 is empty; export a valid apps.json first." >&2
    exit 1
  fi
  if [[ -z "$(echo "${APPS_JSON_BASE64}" | base64 -d 2>/dev/null)" ]]; then
    echo "Decoded APPS_JSON_BASE64 is empty or invalid; please provide apps.json." >&2
    exit 1
  fi
  pushd "${BUILD_CONTEXT}" >/dev/null
  docker build --progress=plain \
    --file "${DOCKERFILE}" \
>>>>>>> main
    --build-arg FRAPPE_PATH="${FRAPPE_PATH}" \
    --build-arg FRAPPE_BRANCH="${FRAPPE_BRANCH}" \
    --build-arg APPS_JSON_BASE64="${APPS_JSON_BASE64}" \
    --tag "${IMAGE_TAG}" \
    . 2>&1 | tee -a build.log
<<<<<<< HEAD
=======
  popd >/dev/null
>>>>>>> main
}

push_image() {
  echo "=== Pushing ${IMAGE_TAG} ==="
  docker push "${IMAGE_TAG}"
}

release_chart() {
  echo "=== Releasing Helm chart ==="
  cd "${HELM_ROOT}"
  ./scripts/release-chart.sh
}

main() {
  build_image
  push_image
  release_chart
}

main "$@"
<<<<<<< HEAD

=======
>>>>>>> main
