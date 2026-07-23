#!/usr/bin/env bash
set -euo pipefail

ROOT="${GASTOWNHALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CITY="${GC_CITY_PATH:-$HOME/city}"

repos=(
  gascity
  gascity-packs
  gascity-dashboard
  beads
  beads-backend-doltlite
)

git_status_line() {
  local dir="$1"
  git -C "$dir" status --short --branch 2>/dev/null | head -1 | sed 's/^[# ]*//'
}

git_head_line() {
  local dir="$1"
  git -C "$dir" log -1 --format='%h %s' 2>/dev/null || printf 'unavailable'
}

printf 'Gastownhall live status\n'
printf 'root: %s\n' "$ROOT"
printf '\n'

for repo in "${repos[@]}"; do
  repo_dir="$ROOT/$repo"
  main_dir="$repo_dir/main"
  live_dir="$repo_dir/live"

  printf '== %s ==\n' "$repo"
  if [[ ! -d "$repo_dir/.git" ]]; then
    printf 'metadata: missing Git metadata directory at %s/.git\n\n' "$repo_dir"
    continue
  fi

  if [[ -d "$main_dir" ]]; then
    printf 'main: %s\n' "$(git_status_line "$main_dir")"
    printf 'main head: %s\n' "$(git_head_line "$main_dir")"
  else
    printf 'main: missing checkout %s\n' "$main_dir"
  fi
  if [[ -d "$live_dir" ]]; then
    printf 'live: %s\n' "$(git_status_line "$live_dir")"
    printf 'live head: %s\n' "$(git_head_line "$live_dir")"
  else
    printf 'live: missing checkout %s\n' "$live_dir"
  fi
  printf '\n'
done

printf '== installed binaries ==\n'
if command -v gc >/dev/null 2>&1; then
  printf 'gc: %s\n' "$(command -v gc)"
  gc version --long 2>/dev/null || gc version 2>/dev/null || true
else
  printf 'gc: missing from PATH\n'
fi

for bin in bd bd-backend-doltlite gc-doltlite-fastpath; do
  if command -v "$bin" >/dev/null 2>&1; then
    path="$(command -v "$bin")"
    printf '%s: %s\n' "$bin" "$path"
    if [[ "$bin" == "bd" ]]; then
      "$bin" version 2>/dev/null || true
    else
      go version -m "$path" 2>/dev/null | grep -E 'path|build[[:space:]]+-tags|CGO_ENABLED' || true
    fi
  else
    printf '%s: missing from PATH\n' "$bin"
  fi
done
printf '\n'

printf '== supervisor / city ==\n'
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user is-active gascity-supervisor.service 2>/dev/null | sed 's/^/supervisor service: /' || true
fi

if command -v gc >/dev/null 2>&1 && [[ -d "$CITY" ]]; then
  (
    cd "$CITY"
    gc supervisor status --json 2>/dev/null | jq -r '"supervisor: ok=\(.ok) pid=\(.pid) binary=\(.binary)"' 2>/dev/null || true
    gc status --json 2>/dev/null | jq -r '"city: ok=\(.ok) usable=\(.health.usable) degraded=\(.health.degraded) signals=\((.health.signals // []) | join(",")) controller=\(.controller.running) beads=\(.beads.beads_store)"' 2>/dev/null || true
    gc beads health --json 2>/dev/null | jq -r '"beads health: ok=\(.ok) status=\(.status)"' 2>/dev/null || true
  )
else
  printf 'city: skipped; gc missing or %s missing\n' "$CITY"
fi
