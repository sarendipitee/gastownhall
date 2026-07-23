#!/usr/bin/env bash
set -euo pipefail

# Smoke-test local gc/bd binaries with a throwaway embedded-Dolt city and
# deterministic agent lifecycle.

ROOT="${SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/gastownhall-local-smoke.XXXXXX")}"
CITY="$ROOT/city"
RIG="$ROOT/scratch"
GC_HOME="$ROOT/gc-home"
WORKSPACE_ROOT="${GASTOWNHALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SYSTEM_BIN_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BACKEND_PLUGIN="$SYSTEM_BIN_DIR/bd-backend-doltlite"
FASTPATH_PLUGIN="$SYSTEM_BIN_DIR/gc-doltlite-fastpath"

LIFECYCLE_EXAMPLE="${LIFECYCLE_EXAMPLE:-$WORKSPACE_ROOT/gascity/live/examples/lifecycle}"
if [ ! -d "$LIFECYCLE_EXAMPLE" ] && [ -d "$WORKSPACE_ROOT/gascity/examples/lifecycle" ]; then
  LIFECYCLE_EXAMPLE="$WORKSPACE_ROOT/gascity/examples/lifecycle"
fi

SUPERVISOR_PID=""

die() {
  printf 'smoke-local-city: %s\n' "$*" >&2
  exit 1
}
has_gastown_pack() {
  python3 - "$CITY/city.toml" <<'PY'
import sys
import tomllib


def has_gastown_source(value):
    return isinstance(value, str) and value.rstrip("/").endswith("/gastown")


def walk(value):
    if isinstance(value, dict):
        if has_gastown_source(value.get("source")):
            return True
        return any(walk(child) for child in value.values())
    if isinstance(value, list):
        return any(walk(child) for child in value)
    return False


with open(sys.argv[1], "rb") as config:
    raise SystemExit(0 if walk(tomllib.load(config)) else 1)
PY
}

cleanup() {
  local code=$?
  if [[ -n "$SUPERVISOR_PID" ]]; then
    kill "$SUPERVISOR_PID" 2>/dev/null || true
    wait "$SUPERVISOR_PID" 2>/dev/null || true
  fi
  pkill -TERM -f "$ROOT" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "$ROOT" 2>/dev/null || true
  if [[ -z "${SMOKE_ROOT:-}" ]]; then
    rm -rf "$ROOT"
  fi
  exit "$code"
}
trap cleanup EXIT

for command in gc bd dolt git; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
for plugin in "$BACKEND_PLUGIN" "$FASTPATH_PLUGIN"; do
  [[ -x "$plugin" ]] || die "missing executable plugin: $plugin"
done

mkdir -p "$ROOT" "$GC_HOME"
git init -q "$RIG"
git -C "$RIG" config user.name smoke
git -C "$RIG" config user.email smoke@example.invalid
git -C "$RIG" commit --allow-empty -qm initial

printf 'initializing throwaway city: %s\n' "$CITY"
[[ -d "$LIFECYCLE_EXAMPLE" ]] || die "Lifecycle example missing at $LIFECYCLE_EXAMPLE (usually found in gascity/live)"
export GC_DOLTLITE_BACKEND_PLUGIN_COMMAND="$BACKEND_PLUGIN"
export GC_DOLTLITE_GASCITY_BACKEND_PLUGIN_COMMAND="$FASTPATH_PLUGIN"
GC_HOME="$GC_HOME" gc init --from "$LIFECYCLE_EXAMPLE" \
  --no-start --yes "$CITY"

GC_HOME="$GC_HOME" gc --city "$CITY" doctor --fix >/dev/null

printf 'testing city Dolt database\n'
GC_HOME="$GC_HOME" bd -C "$CITY" status --json >/dev/null
GC_HOME="$GC_HOME" bd -C "$CITY" list --all --json >/dev/null

printf 'adding throwaway rig\n'
GC_HOME="$GC_HOME" gc --city "$CITY" rig add "$RIG" --name scratch --prefix smk >/dev/null
GC_HOME="$GC_HOME" gc --city "$CITY" rig list | grep -q scratch || die 'rig missing from gc rig list'
GC_HOME="$GC_HOME" bd -C "$RIG" status --json >/dev/null

python3 - "$GC_HOME/cities.toml" "$CITY" <<'PY'
import json
import sys

registry, city = sys.argv[1:]
with open(registry, "w", encoding="utf-8") as f:
    f.write("[[cities]]\n")
    f.write(f"path = {json.dumps(city)}\n")
    f.write('name = "city"\n')
PY
SMOKE_PORT="${SMOKE_PORT:-$(python3 - <<'PY'
import socket

s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)}"
printf '[supervisor]\nport = %s\n' "$SMOKE_PORT" > "$GC_HOME/supervisor.toml"

GC_HOME="$GC_HOME" GC_SUPERVISOR_LOG_TEE=0 gc supervisor run >"$GC_HOME/supervisor.log" 2>&1 &
SUPERVISOR_PID=$!
for _ in $(seq 1 30); do
  if GC_HOME="$GC_HOME" gc supervisor status --json 2>/dev/null | grep -q '"running":true'; then
    break
  fi
  sleep 1
done
GC_HOME="$GC_HOME" gc supervisor status --json | grep -q '"running":true' || die 'isolated supervisor did not start'

if has_gastown_pack; then
  bead="$(GC_HOME="$GC_HOME" bd -C "$RIG" create 'agent lifecycle smoke' --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  GC_HOME="$GC_HOME" gc --city "$CITY" sling scratch/lifecycle.polecat "$bead" --no-formula --json >/dev/null

  printf 'waiting for polecat claim, worktree commit, and refinery handoff\n'
  for _ in $(seq 1 60); do
    status="$(GC_HOME="$GC_HOME" bd -C "$RIG" show "$bead" --json 2>/dev/null | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["status"] if rows else "")' 2>/dev/null || true)"
    if [[ "$status" == in_progress ]] && git -C "$RIG" show "polecat/$bead:$bead.txt" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  GC_HOME="$GC_HOME" bd -C "$RIG" show "$bead" --json | python3 -c '
import json
import sys

row = json.load(sys.stdin)[0]
assert row["status"] == "in_progress", row["status"]
assert row.get("started_at"), "agent never started bead"
assert row.get("assignee") == "scratch/lifecycle.refinery", row.get("assignee")
assert "implemented" in row.get("notes", ""), row.get("notes")
assert row.get("metadata", {}).get("branch") == "polecat/" + row["id"], row.get("metadata")
assert row.get("metadata", {}).get("branch_head"), row.get("metadata")
'
  git -C "$RIG" show "polecat/$bead:$bead.txt" >/dev/null || die 'polecat worktree commit missing'

  printf 'waiting for refinery merge and bead closure\n'
  for _ in $(seq 1 60); do
    status="$(GC_HOME="$GC_HOME" bd -C "$RIG" show "$bead" --json 2>/dev/null | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["status"] if rows else "")' 2>/dev/null || true)"
    if [[ "$status" == closed ]] && git -C "$RIG" show "main:$bead.txt" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  GC_HOME="$GC_HOME" bd -C "$RIG" show "$bead" --json | python3 -c '
import json
import sys

row = json.load(sys.stdin)[0]
assert row["status"] == "closed", row["status"]
assert row.get("metadata", {}).get("merge_result") == "merged", row.get("metadata")
assert "merged polecat/" in row.get("notes", ""), row.get("notes")
'
  git -C "$RIG" show "main:$bead.txt" >/dev/null || die 'refinery merge missing from main'
  [[ ! -e "/tmp/gc-scripted-wt/$bead" ]] || die 'polecat worktree remains after handoff'
else
  printf 'skipping polecat/refinery lifecycle assertions: gastown pack not imported\n'
fi

GC_HOME="$GC_HOME" gc --city "$CITY" beads health --json >/dev/null
GC_HOME="$GC_HOME" gc --city "$CITY" doctor >/dev/null
printf 'PASS: local Dolt city smoke\n'
