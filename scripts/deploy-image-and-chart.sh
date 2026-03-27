#!/usr/bin/env bash
set -euo pipefail

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

IMAGE_TAG="${IMAGE_TAG:-ghcr.io/green-llama/glerp-image:dev}"
FRAPPE_PATH="${FRAPPE_PATH:-https://github.com/green-llama/frappe-gl}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-develop}"
APPS_JSON="${APPS_JSON:-/home/greenllama/frappe_docker_dev/development/apps.json}"
HELM_ROOT="${HELM_ROOT:-/home/greenllama/helm-glerp}"

build_image() {
  echo "=== Building image ${IMAGE_TAG} ==="
  if [[ ! -f "${APPS_JSON}" ]]; then
    echo "apps.json not found at ${APPS_JSON}" >&2
    exit 1
  fi
  APPS_JSON_BASE64=$(base64 -w0 "${APPS_JSON}")
  docker build --progress=plain \
    --file images/layered/Containerfile \
    --build-arg FRAPPE_PATH="${FRAPPE_PATH}" \
    --build-arg FRAPPE_BRANCH="${FRAPPE_BRANCH}" \
    --build-arg APPS_JSON_BASE64="${APPS_JSON_BASE64}" \
    --tag "${IMAGE_TAG}" \
    . 2>&1 | tee -a build.log
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

