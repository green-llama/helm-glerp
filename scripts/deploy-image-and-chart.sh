#!/usr/bin/env bash
set -euo pipefail

# One-shot helper to build & push the GLerp image and release the Helm chart.
#
# This script intentionally does not pass apps.json as a build-arg. Private app
# credentials are mounted as a BuildKit secret so they do not end up in image
# history or runtime environment.
#
# Requirements:
#   - docker with BuildKit support
#   - docker login ghcr.io
#   - GitHub token available via GITHUB_TOKEN/GH_TOKEN or `gh auth login`
#   - helm installed locally
#
# Environment overrides:
#   IMAGE_TAG                (default: ghcr.io/green-llama/glerp-image:dev)
#   FRAPPE_PATH              (default: https://github.com/green-llama/frappe-gl)
#   FRAPPE_BRANCH            (default: version-16)
#   APPS_JSON                (default: /home/greenllama/frappe_docker_dev/development/apps.json)
#   APPS_GITHUB_TOKEN        (optional, used to rewrite private green-llama repo URLs in apps.json)
#   HELM_ROOT                (default: /home/greenllama/helm-glerp)
#   BUILD_CONTEXT            (default: /home/greenllama/frappe_docker_dev)
#   BUILD_LOG                (default: /home/greenllama/helm-glerp/scripts/build.log)
#   CHART_DIR                (default: erpnext)
#   HELM_VALUES_FILE         (default: ${HELM_ROOT}/erpnext/values.yaml)
#   HELM_CHART_FILE          (default: ${HELM_ROOT}/erpnext/Chart.yaml)
#   RUN_BENCH_BUILD          (default: true)
#   BENCH_BUILD_ARGS         (default: --force)
#   AUTO_UPDATE_CHART_IMAGE  (default: true)
#   AUTO_BUMP_CHART_VERSION  (default: true)
#   SKIP_BUILD               (default: false)
#   SKIP_PUSH                (default: false)
#   SKIP_RELEASE             (default: false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_TAG="${IMAGE_TAG:-ghcr.io/green-llama/glerp-image:dev}"
FRAPPE_PATH="${FRAPPE_PATH:-https://github.com/green-llama/frappe-gl}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-16}"
APPS_JSON="${APPS_JSON:-/home/greenllama/frappe_docker_dev/development/apps.json}"
APPS_GITHUB_TOKEN="${APPS_GITHUB_TOKEN:-}"
HELM_ROOT="${HELM_ROOT:-/home/greenllama/helm-glerp}"
BUILD_CONTEXT="${BUILD_CONTEXT:-/home/greenllama/frappe_docker_dev}"
BUILD_LOG="${BUILD_LOG:-${SCRIPT_DIR}/build.log}"
CHART_DIR="${CHART_DIR:-erpnext}"
HELM_VALUES_FILE="${HELM_VALUES_FILE:-${HELM_ROOT}/erpnext/values.yaml}"
HELM_CHART_FILE="${HELM_CHART_FILE:-${HELM_ROOT}/erpnext/Chart.yaml}"
RUN_BENCH_BUILD="${RUN_BENCH_BUILD:-true}"
BENCH_BUILD_ARGS="${BENCH_BUILD_ARGS:---force}"
AUTO_UPDATE_CHART_IMAGE="${AUTO_UPDATE_CHART_IMAGE:-true}"
AUTO_BUMP_CHART_VERSION="${AUTO_BUMP_CHART_VERSION:-true}"
SKIP_BUILD="${SKIP_BUILD:-false}"
SKIP_PUSH="${SKIP_PUSH:-false}"
SKIP_RELEASE="${SKIP_RELEASE:-false}"

tmp_dir=""
temp_dockerfile=""
image_repository=""
image_version=""
resolved_apps_json=""
build_github_token=""

cleanup() {
  if [[ -n "${tmp_dir}" && -d "${tmp_dir}" ]]; then
    rm -rf "${tmp_dir}"
  fi
}

trap cleanup EXIT

bool_is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
}

parse_image_tag() {
  if [[ "${IMAGE_TAG}" != *:* ]]; then
    echo "IMAGE_TAG must include an explicit tag, got: ${IMAGE_TAG}" >&2
    exit 1
  fi

  image_repository="${IMAGE_TAG%:*}"
  image_version="${IMAGE_TAG##*:}"
}

print_build_config() {
  echo "=== Build configuration ==="
  echo "IMAGE_TAG: ${IMAGE_TAG}"
  echo "FRAPPE_PATH: ${FRAPPE_PATH}"
  echo "FRAPPE_BRANCH: ${FRAPPE_BRANCH}"
  echo "APPS_JSON: ${APPS_JSON}"
  echo "BUILD_CONTEXT: ${BUILD_CONTEXT}"
  echo "BUILD_LOG: ${BUILD_LOG}"
  echo "HELM_VALUES_FILE: ${HELM_VALUES_FILE}"
  echo "HELM_CHART_FILE: ${HELM_CHART_FILE}"
  echo "RUN_BENCH_BUILD: ${RUN_BENCH_BUILD}"
  echo "BENCH_BUILD_ARGS: ${BENCH_BUILD_ARGS}"
}

validate_inputs() {
  require_command docker
  require_command helm
  require_command git
  require_command python3

  [[ -d "${BUILD_CONTEXT}" ]] || {
    echo "Build context not found: ${BUILD_CONTEXT}" >&2
    exit 1
  }

  [[ -f "${APPS_JSON}" ]] || {
    echo "apps.json not found at ${APPS_JSON}" >&2
    exit 1
  }

  [[ -s "${APPS_JSON}" ]] || {
    echo "apps.json is empty: ${APPS_JSON}" >&2
    exit 1
  }

  python3 - "${APPS_JSON}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
if not isinstance(data, list) or not data:
    raise SystemExit("apps.json must contain a non-empty list of apps")
PY

  [[ -f "${HELM_VALUES_FILE}" ]] || {
    echo "Helm values file not found: ${HELM_VALUES_FILE}" >&2
    exit 1
  }

  [[ -f "${HELM_CHART_FILE}" ]] || {
    echo "Helm Chart.yaml not found: ${HELM_CHART_FILE}" >&2
    exit 1
  }

  docker info >/dev/null
}

resolve_build_github_token() {
  if [[ -n "${APPS_GITHUB_TOKEN}" ]]; then
    build_github_token="${APPS_GITHUB_TOKEN}"
    return
  fi

  build_github_token="$(env -u GITHUB_TOKEN -u GH_TOKEN gh auth token 2>/dev/null || true)"
  if [[ -n "${build_github_token}" ]]; then
    return
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    build_github_token="${GITHUB_TOKEN}"
    return
  fi

  if [[ -n "${GH_TOKEN:-}" ]]; then
    build_github_token="${GH_TOKEN}"
  fi
}

prepare_apps_json_secret() {
  [[ -n "${tmp_dir}" ]] || tmp_dir="$(mktemp -d)"
  resolved_apps_json="${tmp_dir}/apps.json"
  resolve_build_github_token

  python3 - "${APPS_JSON}" "${resolved_apps_json}" "${build_github_token}" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
token = sys.argv[3]

apps = json.loads(src.read_text())
needs_token = False

for app in apps:
    url = app.get("url", "")
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    path = parsed.path or ""
    is_green_llama = host == "github.com" and path.startswith("/green-llama/")
    has_embedded_creds = "@" in parsed.netloc

    if is_green_llama:
        needs_token = True

    if token and is_green_llama:
        app["url"] = urlunsplit(
            (
                parsed.scheme or "https",
                f"x-access-token:{token}@github.com",
                parsed.path,
                parsed.query,
                parsed.fragment,
            )
        )
    elif has_embedded_creds and host == "github.com" and token:
        app["url"] = urlunsplit(
            (
                parsed.scheme or "https",
                f"x-access-token:{token}@github.com",
                parsed.path,
                parsed.query,
                parsed.fragment,
            )
        )

if needs_token and not token:
    raise SystemExit(
        "apps.json references private green-llama GitHub repos but no usable token was found. "
        "Set APPS_GITHUB_TOKEN or run `gh auth login`."
    )

dst.write_text(json.dumps(apps, indent=2) + "\n")
PY
}

render_secure_dockerfile() {
  [[ -n "${tmp_dir}" ]] || tmp_dir="$(mktemp -d)"
  temp_dockerfile="${tmp_dir}/Containerfile.secure"

  cat >"${temp_dockerfile}" <<EOF
# syntax=docker/dockerfile:1.7
ARG FRAPPE_BRANCH=${FRAPPE_BRANCH}
FROM frappe/build:\${FRAPPE_BRANCH} AS builder
ARG FRAPPE_BRANCH
ARG FRAPPE_PATH=${FRAPPE_PATH}
ARG RUN_BENCH_BUILD=${RUN_BENCH_BUILD}
ARG BENCH_BUILD_ARGS=${BENCH_BUILD_ARGS}

USER frappe

RUN --mount=type=secret,id=apps_json,target=/run/secrets/apps.json,uid=1000,gid=1000,mode=0400 \\
  export APP_INSTALL_ARGS="" && \\
  if [ -s /run/secrets/apps.json ]; then \\
    export APP_INSTALL_ARGS="--apps_path=/run/secrets/apps.json"; \\
  fi && \\
  bench init \${APP_INSTALL_ARGS} \\
    --frappe-branch=\${FRAPPE_BRANCH} \\
    --frappe-path=\${FRAPPE_PATH} \\
    --no-procfile \\
    --no-backups \\
    --skip-redis-config-generation \\
    --verbose \\
    /home/frappe/frappe-bench && \\
  cd /home/frappe/frappe-bench && \\
  echo "{}" > sites/common_site_config.json && \\
  if [ "\${RUN_BENCH_BUILD}" = "true" ]; then \\
    bench build \${BENCH_BUILD_ARGS}; \\
  fi && \\
  find apps -mindepth 1 -path "*/.git" | xargs rm -fr

FROM frappe/base:\${FRAPPE_BRANCH} AS backend
ARG FRAPPE_BRANCH

USER frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

VOLUME [ \\
  "/home/frappe/frappe-bench/sites", \\
  "/home/frappe/frappe-bench/sites/assets", \\
  "/home/frappe/frappe-bench/logs" \\
]

CMD [ \\
  "/home/frappe/frappe-bench/env/bin/gunicorn", \\
  "--chdir=/home/frappe/frappe-bench/sites", \\
  "--bind=0.0.0.0:8000", \\
  "--threads=4", \\
  "--workers=2", \\
  "--worker-class=gthread", \\
  "--worker-tmp-dir=/dev/shm", \\
  "--timeout=120", \\
  "--preload", \\
  "frappe.app:application" \\
]
EOF
}

update_chart_files() {
  if ! bool_is_true "${AUTO_UPDATE_CHART_IMAGE}"; then
    return
  fi

  echo "=== Updating chart image reference to ${IMAGE_TAG} ==="
  python3 - "${HELM_VALUES_FILE}" "${image_repository}" "${image_version}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
repo = sys.argv[2]
tag = sys.argv[3]
lines = path.read_text().splitlines()
in_image = False
repo_done = False
tag_done = False

for idx, line in enumerate(lines):
    if line.startswith("image:"):
        in_image = True
        continue
    if in_image and line and not line.startswith("  "):
        in_image = False
    if not in_image:
        continue
    if line.startswith("  repository:"):
        lines[idx] = f"  repository: {repo}"
        repo_done = True
    elif line.startswith("  tag:"):
        lines[idx] = f"  tag: {tag}"
        tag_done = True

if not repo_done or not tag_done:
    raise SystemExit(f"Could not update image.repository/tag in {path}")

path.write_text("\n".join(lines) + "\n")
PY

  if ! bool_is_true "${AUTO_BUMP_CHART_VERSION}"; then
    return
  fi

  echo "=== Bumping chart patch version ==="
  python3 - "${HELM_CHART_FILE}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()

for idx, line in enumerate(lines):
    if not line.startswith("version: "):
        continue
    current = line.split(": ", 1)[1].strip()
    parts = current.split(".")
    if len(parts) != 3:
        raise SystemExit(f"Expected semantic version in {path}, got {current}")
    parts[-1] = str(int(parts[-1]) + 1)
    updated = ".".join(parts)
    lines[idx] = f"version: {updated}"
    print(f"Chart version: {current} -> {updated}")
    path.write_text("\n".join(lines) + "\n")
    break
else:
    raise SystemExit(f"version field not found in {path}")
PY
}

build_image() {
  if bool_is_true "${SKIP_BUILD}"; then
    echo "=== Skipping image build ==="
    return
  fi

  echo "=== Building image ${IMAGE_TAG} ==="
  prepare_apps_json_secret
  render_secure_dockerfile

  mkdir -p "$(dirname "${BUILD_LOG}")"

  (
    cd "${BUILD_CONTEXT}"
    DOCKER_BUILDKIT=1 docker build --progress=plain \
      --file "${temp_dockerfile}" \
      --build-arg FRAPPE_PATH="${FRAPPE_PATH}" \
      --build-arg FRAPPE_BRANCH="${FRAPPE_BRANCH}" \
      --build-arg RUN_BENCH_BUILD="${RUN_BENCH_BUILD}" \
      --build-arg BENCH_BUILD_ARGS="${BENCH_BUILD_ARGS}" \
      --secret id=apps_json,src="${resolved_apps_json}" \
      --tag "${IMAGE_TAG}" \
      .
  ) 2>&1 | tee -a "${BUILD_LOG}"
}

push_image() {
  if bool_is_true "${SKIP_PUSH}"; then
    echo "=== Skipping image push ==="
    return
  fi

  echo "=== Pushing ${IMAGE_TAG} ==="
  docker push "${IMAGE_TAG}"
}

release_chart() {
  if bool_is_true "${SKIP_RELEASE}"; then
    echo "=== Skipping chart release ==="
    return
  fi

  echo "=== Releasing Helm chart ==="
  (
    cd "${HELM_ROOT}"
    ALLOW_DIRTY_CHART_CHANGES=true ./scripts/release-chart.sh "${CHART_DIR}"
  )
}

main() {
  parse_image_tag
  validate_inputs
  print_build_config
  update_chart_files
  build_image
  push_image
  release_chart
}

main "$@"
