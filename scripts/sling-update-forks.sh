#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "${GASTOWNHALL_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd -P)"
CITY="${GC_CITY_PATH:-$HOME/city}"
FORMULA="do-work"
RIGS="gascity-source,gascity-packs-source,gascity-dashboard,beads-source,beads-backend-doltlite-source"
DEFAULT_TARGET_SUFFIX="gastown.polecat"
APPLY=0
ALLOW_LAYOUT_FAIL=0
SLING_ARGS=()
TARGET_OVERRIDES=()

usage() {
  cat <<'USAGE'
usage: scripts/sling-update-forks.sh [--apply] [options]

Create one update-fork bead per rig and sling it through a formula.
Dry-run is default.

Options:
  --apply                 create beads and sling them
  --rigs a,b,c            comma-separated rig names
  --formula NAME          formula to attach with gc sling --on (default: do-work)
  --target rig=agent      override sling target for one rig
  --target-suffix NAME    default target suffix (default: gastown.polecat)
  --allow-layout-fail     allow apply even if assert-live-layout.sh fails
  --sling-arg ARG         extra arg passed to gc sling, repeatable
  -h, --help              show help
USAGE
}

while (($#)); do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --rigs)
      RIGS="${2:?--rigs requires value}"
      shift 2
      ;;
    --rigs=*)
      RIGS="${1#*=}"
      shift
      ;;
    --formula)
      FORMULA="${2:?--formula requires value}"
      shift 2
      ;;
    --formula=*)
      FORMULA="${1#*=}"
      shift
      ;;
    --target)
      TARGET_OVERRIDES+=("${2:?--target requires rig=agent}")
      shift 2
      ;;
    --target=*)
      TARGET_OVERRIDES+=("${1#*=}")
      shift
      ;;
    --target-suffix)
      DEFAULT_TARGET_SUFFIX="${2:?--target-suffix requires value}"
      shift 2
      ;;
    --target-suffix=*)
      DEFAULT_TARGET_SUFFIX="${1#*=}"
      shift
      ;;
    --allow-layout-fail)
      ALLOW_LAYOUT_FAIL=1
      shift
      ;;
    --sling-arg)
      SLING_ARGS+=("${2:?--sling-arg requires value}")
      shift 2
      ;;
    --sling-arg=*)
      SLING_ARGS+=("${1#*=}")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need gc
need jq

cd "$CITY"

echo "== live status =="
"$ROOT/scripts/live-status.sh"
echo

echo "== live layout =="
if ! "$ROOT/scripts/assert-live-layout.sh"; then
  if ((APPLY == 1 && ALLOW_LAYOUT_FAIL == 0)); then
    echo "layout check failed; rerun with --allow-layout-fail only if this is intentional" >&2
    exit 1
  fi
fi
echo

if ! gc formula show "$FORMULA" >/dev/null 2>&1; then
  echo "formula not found: $FORMULA" >&2
  exit 1
fi

IFS=',' read -r -a rig_list <<<"$RIGS"
created=()

target_for_rig() {
  local rig="$1" override
  for override in "${TARGET_OVERRIDES[@]}"; do
    if [[ "$override" == "$rig="* ]]; then
      printf '%s\n' "${override#*=}"
      return 0
    fi
  done
  printf '%s/%s\n' "$rig" "$DEFAULT_TARGET_SUFFIX"
}

make_body() {
  local rig="$1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat <<EOF
Update fork/repo state for rig \`$rig\`.

Timestamp: $now

Rules:
- Read \`$ROOT/AGENTS.md\` before changing git state.
- Component parent \`.git\` is bare shared metadata. Work in direct named child worktrees such as \`main\`, \`live\`, or a feature branch; do not create or use \`work/\`, and do not alter \`<city>/.gc/worktrees/...\` City runtime state.
- Do not hide dirty state. If \`main\` or \`live\` is dirty, report exact files before proceeding.
- Do not use destructive git operations unless policy explicitly permits the exact operation and the pre-state is recorded.
- Use \`git push --force-with-lease\`, never plain force, when updating fork branches that policy says are disposable.

Required inspection:
- Print \`pwd\`, \`git remote -v\`, \`git status --short --branch\`.
- Print \`git worktree list\`.
- Fetch \`origin\` and \`upstream\` with prune when both remotes exist.
- Print current \`main\`, \`upstream/main\`, \`origin/main\`, and \`live\` SHAs when present.

Main/fork update:
- Ensure child checkout \`main\` exists and is on \`main\`.
- If \`upstream/main\` exists and \`main\` is clean, sync \`main\` to \`upstream/main\` per workspace policy.
- If \`origin/main\` exists and should mirror \`upstream/main\`, push with \`--force-with-lease\` after verifying exact SHAs.

Live/integration check:
- Ensure child checkout \`live\` exists and is on \`live\`.
- Compare \`live\` with any configured integration branch such as \`origin/integration/live-20260706\`.
- If new integration work exists, merge/rebase only after recording source commits and expected conflicts.
- Keep \`live\` clean at handoff.

Validation:
- Run repo-appropriate checks:
  - \`gascity-source\`: focused Go tests and \`make check-self-contained\` if binary-affecting.
  - \`gascity-packs-source\`: \`bash -n\` for changed scripts and pack tests when relevant.
  - \`gascity-dashboard\`: package tests for changed frontend/backend areas.
  - \`beads-source\`: focused Go tests for changed packages; include website/npm checks when those files change.
  - \`beads-backend-doltlite-source\`: focused Go tests and plugin build checks when backend/runtime code changes.
  - other rigs: existing repo test/build commands discovered from docs.
- Run \`$ROOT/scripts/live-status.sh\`.
- Run \`$ROOT/scripts/assert-live-layout.sh\`; if it fails, explain why.

Handoff:
- Report exact branch names, SHAs before/after, commands run, pushes performed, validation results, and remaining dirty state.
EOF
}

for rig in "${rig_list[@]}"; do
  rig="${rig//[[:space:]]/}"
  [[ -n "$rig" ]] || continue

  title="Update fork state for $rig"
  body="$(make_body "$rig")"
  target="$(target_for_rig "$rig")"

  echo "== $rig =="
  if ((APPLY == 0)); then
    echo "DRY RUN: would create chore bead:"
    echo "  title: $title"
    echo "  rig: $rig"
    echo "  target: $target"
    echo "  formula: $FORMULA"
    echo "$body" | sed 's/^/  | /'
    echo
    continue
  fi

  create_json="$(gc bd create --rig "$rig" --json --type chore --priority 2 --title "$title" --stdin <<<"$body")"
  bead_id="$(jq -r '.id // empty' <<<"$create_json")"
  if [[ -z "$bead_id" ]]; then
    echo "failed to create bead for $rig: $create_json" >&2
    exit 1
  fi

  sling_json="$(gc sling "$target" "$bead_id" --on "$FORMULA" --json --force "${SLING_ARGS[@]}")"
  created+=("$rig:$bead_id:$target")
  echo "$sling_json" | jq .
done

if ((APPLY == 0)); then
  echo "dry run only; rerun with --apply to create and sling beads"
else
  echo "created:"
  printf '  %s\n' "${created[@]}"
fi
