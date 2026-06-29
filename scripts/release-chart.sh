#!/usr/bin/env bash
set -euo pipefail

# End-to-end release helper for helm-glerp.
# Steps:
#   - Rebuild .helm-repo (package chart + index)
#   - Commit/push changes on main
#   - Merge main into gh-pages, copy artifacts, commit/push
#
# Usage:
#   ./scripts/release-chart.sh [chart_dir] [repo_dir] [repo_url]
# Defaults:
#   chart_dir: erpnext
#   repo_dir:  .helm-repo
#   repo_url:  https://green-llama.github.io/helm-glerp
#
# Notes:
#   - Requires clean working tree before starting.
#   - Leaves you on your original branch.
#   - Uses GITHUB_TOKEN/GH_TOKEN or `gh auth token` for authenticated pushes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITHUB_TOKEN="ghp_XywDRIRtCqDhlmFUprr4Sk1v8metda1qSKEz"
cd "${REPO_ROOT}"

CHART_DIR="${1:-erpnext}"
REPO_DIR="${2:-.helm-repo}"
REPO_URL="${3:-https://green-llama.github.io/helm-glerp}"

start_branch="$(git rev-parse --abbrev-ref HEAD)"
askpass_dir=""
askpass_script=""

cleanup() {
  if [[ -n "${askpass_dir}" && -d "${askpass_dir}" ]]; then
    rm -rf "${askpass_dir}"
  fi
}

trap cleanup EXIT

setup_github_token_auth() {
  local github_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  local token_source="environment"

  if [[ -z "${github_token}" ]] && command -v gh >/dev/null 2>&1; then
    github_token="$(gh auth token 2>/dev/null || true)"
    if [[ -n "${github_token}" ]]; then
      token_source="gh auth token"
    fi
  fi

  if [[ -z "${github_token}" ]]; then
    echo "No GitHub token found. Set GITHUB_TOKEN or GH_TOKEN, or run 'gh auth login'." >&2
    exit 1
  fi

  askpass_dir="$(mktemp -d)"
  askpass_script="${askpass_dir}/git-askpass.sh"
  cat >"${askpass_script}" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "${GITHUB_TOKEN}" ;;
esac
EOF
  chmod 700 "${askpass_script}"

  export GITHUB_TOKEN="${github_token}"
  export GIT_ASKPASS="${askpass_script}"
  export GIT_TERMINAL_PROMPT=0

  echo "=== Using GitHub token from ${token_source} for git pushes ==="
}

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree is dirty. Commit or stash changes first." >&2
  exit 1
fi

echo "=== Rebuilding ${REPO_DIR} ==="
rm -rf "${REPO_DIR}"
mkdir -p "${REPO_DIR}"
helm package "${CHART_DIR}" -d "${REPO_DIR}"
helm repo index "${REPO_DIR}" --url "${REPO_URL}"

echo "=== Committing chart changes on main ==="
git add "${CHART_DIR}/Chart.yaml" "${REPO_DIR}/index.yaml" "${REPO_DIR}"/*.tgz
git commit -m "release $(basename "${CHART_DIR}") $(date +%Y-%m-%d)" || true
setup_github_token_auth
git push origin main

echo "=== Publishing to gh-pages ==="
git checkout gh-pages
git merge --no-ff main -m "Merge main into gh-pages for release $(date +%Y-%m-%d)" || {
  echo "Merge failed; resolve conflicts on gh-pages and re-run from gh-pages after fixing." >&2
  exit 1
}
cp -a "${REPO_DIR}/." .
git add *.tgz index.yaml
git commit -m "publish helm repo $(date +%Y-%m-%d)" || true
git push origin gh-pages

echo "=== Restoring branch ${start_branch} ==="
git checkout "${start_branch}"

echo "Done. Rancher can now refresh the repo URL: ${REPO_URL}"
