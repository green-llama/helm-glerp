#!/usr/bin/env bash
set -euo pipefail

# End-to-end release helper:
# - Rebuild .helm-repo from scratch (tarballs + index)
# - Commit/push chart changes on main
# - Checkout gh-pages, merge main, copy artifacts to root, commit/push
#
# Usage:
#   ./scripts/release-chart.sh [chart_dir] [repo_dir] [repo_url]
# Defaults match this repo:
#   chart_dir: erpnext
#   repo_dir:  .helm-repo
#   repo_url:  https://green-llama.github.io/helm-glerp
#
# Notes:
# - Expects a clean working tree on main before running.
# - Leaves you on the branch you started from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

CHART_DIR="${1:-erpnext}"
REPO_DIR="${2:-.helm-repo}"
REPO_URL="${3:-https://green-llama.github.io/helm-glerp}"

start_branch="$(git rev-parse --abbrev-ref HEAD)"

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
