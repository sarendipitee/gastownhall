#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_TIMEOUT_INPUT="${E2E_TIMEOUT_SECONDS:-1800}"
TOTAL_TIMEOUT_SECONDS="${E2E_TOTAL_TIMEOUT_SECONDS:-$((WORKFLOW_TIMEOUT_INPUT + 180))}"
COMMAND_TIMEOUT_SECONDS="${E2E_COMMAND_TIMEOUT_SECONDS:-30}"
for value_name in WORKFLOW_TIMEOUT_INPUT TOTAL_TIMEOUT_SECONDS COMMAND_TIMEOUT_SECONDS; do
  value="${!value_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    printf 'e2e-build-basic: FAIL: %s must be a positive integer: %s\n' "$value_name" "$value" >&2
    exit 1
  }
done
if [[ "${E2E_WATCHDOG_ACTIVE:-0}" != "1" ]]; then
  set +e
  timeout --foreground --signal=TERM --kill-after=30s "${TOTAL_TIMEOUT_SECONDS}s" \
    env E2E_WATCHDOG_ACTIVE=1 bash "$0" "$@"
  code=$?
  set -e
  if [[ "$code" == "124" || "$code" == "137" ]]; then
    printf 'e2e-build-basic: FAIL: probe exceeded total timeout of %ss\n' "$TOTAL_TIMEOUT_SECONDS" >&2
  fi
  exit "$code"
fi

# End-to-end probe for the installed gc binary and Sarendipitee live Gas City
# pack. Everything created by this script lives under one disposable root.
#
# Environment variables used:
# - GASCITY_PACK_SOURCE: Path or URL to the gascity pack.
# - GASCITY_PACK_REPOSITORY: Repository URL for the pack.
# - E2E_CODEX_MODEL / E2E_MODEL: Model identifier to use.
# - E2E_GC_BIN: Path to the gc binary.
# - E2E_PRODUCTION_PORT: Port for the supervisor.
# - OPENAI_API_KEY / OMP_API_KEY: Required for model authentication.

if [[ -z "${OPENAI_API_KEY:-}" ]] && [[ -z "${OMP_API_KEY:-}" ]] && [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${GEMINI_API_KEY:-}" ]]; then
  printf 'e2e-build-basic: FAIL: A model credential (e.g. OPENAI_API_KEY, OMP_API_KEY) must be set.\n' >&2
  exit 1
fi


if [[ -n "${E2E_ROOT+x}" ]]; then
  ROOT="$E2E_ROOT"
  [[ ! -e "$ROOT" ]] || {
    printf 'e2e-build-basic: FAIL: E2E_ROOT already exists: %s\n' "$ROOT" >&2
    exit 1
  }
else
  ROOT="$(mktemp -d "/var/tmp/gastownhall-build-basic-e2e.XXXXXX")"
fi
ROOT_PARENT="${ROOT%/*}"
ROOT_NAME="${ROOT##*/}"
[[ "$ROOT_PARENT" == "/var/tmp" && "$ROOT_NAME" =~ ^gastownhall-build-basic-e2e[.-][A-Za-z0-9._-]+$ ]] || {
  printf 'e2e-build-basic: FAIL: disposable root must be a direct /var/tmp/gastownhall-build-basic-e2e.* path: %s\n' "$ROOT" >&2
  exit 1
}
CITY="$ROOT/city"
RIG="$ROOT/rig"
GC_HOME="$ROOT/gc-home"
PROBE_TMP="$ROOT/tmp"
PROBE_BIN_DIR="$ROOT/bin"
PACK_SOURCE="${GASCITY_PACK_SOURCE:-https://github.com/gastownhall/gascity-packs/tree/live/gascity}"
PACK_REPOSITORY="${GASCITY_PACK_REPOSITORY:-https://github.com/gastownhall/gascity-packs}"
PROVIDER="${E2E_PROVIDER:-omp}"
MODEL="${E2E_MODEL:-${E2E_CODEX_MODEL:-omniroute/codex/gpt-5.6-luna}}"
GC_BIN="${E2E_GC_BIN:-gc}"
RIG_PREFIX="${E2E_RIG_PREFIX:-e2e$(python3 -c 'import secrets; print(secrets.token_hex(3))')}"
CITY_NAME="${E2E_CITY_NAME:-e2e-build-basic-$RIG_PREFIX}"
CONFIG_ONLY="${E2E_CONFIG_ONLY:-0}"
TIMEOUT_SECONDS="$WORKFLOW_TIMEOUT_INPUT"
POLL_SECONDS="${E2E_POLL_SECONDS:-15}"
KEEP_ROOT="${E2E_KEEP_ROOT:-1}"
PRODUCTION_PORT="${E2E_PRODUCTION_PORT:-8372}"
SUPERVISOR_PID=""
SUPERVISOR_UNIT=""
START_ATTEMPTED=0
WORKFLOW_ID=""
TASK_ID=""
STARTED_AT=""
PRODUCTION_BEFORE=""
GC_BIN_PATH=""
GC_BIN_CANONICAL=""
PACK_LOCAL=0
PACK_REPO_ROOT=""
PACK_COMMIT=""
PACK_STATUS_BEFORE=""
PACK_SOURCE_HASH_BEFORE=""
PACK_PROVENANCE_REPO="${GASCITY_PACK_PROVENANCE_REPO:-}"
PACK_PROVENANCE_SUBDIR="${GASCITY_PACK_PROVENANCE_SUBDIR:-}"

log() { printf 'e2e-build-basic: %s\n' "$*"; }
die() { printf 'e2e-build-basic: FAIL: %s\n' "$*" >&2; exit 1; }

run_bounded() {
  timeout --foreground --signal=TERM --kill-after=10s "${COMMAND_TIMEOUT_SECONDS}s" "$@"
}

kill_root_processes() {
  local signal="$1" pid
  while read -r pid; do
    [[ -n "$pid" && "$pid" != "$$" && "$pid" != "$PPID" ]] || continue
    kill "-$signal" "$pid" 2>/dev/null || true
  done < <(pgrep -f -- "$ROOT" || true)
}

capture_evidence() {
  set +e
  mkdir -p "$ROOT/evidence"
  {
    printf 'root=%s\ncity=%s\ncity_name=%s\nrig=%s\ngc_home=%s\ntmpdir=%s\n' "$ROOT" "$CITY" "$CITY_NAME" "$RIG" "$GC_HOME" "$PROBE_TMP"
    printf 'gc_bin=%s\ngc_canonical=%s\ngc_alias=%s\nsupervisor_pid=%s\nsupervisor_unit=%s\n' \
      "$GC_BIN_PATH" "$GC_BIN_CANONICAL" "$PROBE_BIN_DIR/gc" "$SUPERVISOR_PID" "$SUPERVISOR_UNIT"
    printf 'pack_source=%s\npack_version=%s\npack_local=%s\npack_repo_root=%s\npack_commit=%s\npack_provenance_subdir=%s\npack_source_hash=%s\n' \
      "$PACK_SOURCE" "${PACK_VERSION:-}" "$PACK_LOCAL" "$PACK_REPO_ROOT" "$PACK_COMMIT" \
      "$PACK_PROVENANCE_SUBDIR" "$PACK_SOURCE_HASH_BEFORE"
    printf 'workflow_id=%s\ntask_id=%s\nstarted_at=%s\n' "$WORKFLOW_ID" "$TASK_ID" "$STARTED_AT"
    printf 'workflow_timeout_seconds=%s\ntotal_timeout_seconds=%s\ncommand_timeout_seconds=%s\npoll_seconds=%s\n' \
      "$TIMEOUT_SECONDS" "$TOTAL_TIMEOUT_SECONDS" "$COMMAND_TIMEOUT_SECONDS" "$POLL_SECONDS"
  } > "$ROOT/evidence/run.env"
  if [[ -n "$GC_BIN_PATH" && -x "$GC_BIN_PATH" ]]; then
    sha256sum "$GC_BIN_PATH" > "$ROOT/evidence/gc.sha256"
    go version -m "$GC_BIN_PATH" > "$ROOT/evidence/gc-build.txt" 2>&1
    "$GC_BIN_PATH" version > "$ROOT/evidence/gc-version.txt" 2>&1
  fi
  [[ -f "$CITY/city.toml" ]] && cp "$CITY/city.toml" "$ROOT/evidence/city.toml"
  [[ -f "$CITY/pack.toml" ]] && cp "$CITY/pack.toml" "$ROOT/evidence/pack.toml"
  [[ -f "$CITY/packs.lock" ]] && cp "$CITY/packs.lock" "$ROOT/evidence/packs.lock"
  if [[ "$PACK_LOCAL" == "1" && -n "$PACK_REPO_ROOT" ]]; then
    git -C "$PACK_REPO_ROOT" rev-parse HEAD > "$ROOT/evidence/pack-source-head.txt" 2>&1
    git -C "$PACK_REPO_ROOT" status --porcelain=v1 --untracked-files=all > "$ROOT/evidence/pack-source-status.txt" 2>&1
  fi
  [[ -f "$GC_HOME/supervisor.log" ]] && cp "$GC_HOME/supervisor.log" "$ROOT/evidence/supervisor.log"
  [[ -f "$CITY/.gc/events.jsonl" ]] && cp "$CITY/.gc/events.jsonl" "$ROOT/evidence/events.jsonl"
  [[ -f "$CITY/.gc/runtime/probe--core.control-dispatcher-trace.log" ]] && \
    cp "$CITY/.gc/runtime/probe--core.control-dispatcher-trace.log" "$ROOT/evidence/control-dispatcher-trace.log"
  if command -v herdr >/dev/null 2>&1; then
    run_bounded herdr --session "$CITY_NAME" status server --json > "$ROOT/evidence/herdr-status.json" 2>&1
    run_bounded herdr --session "$CITY_NAME" agent list > "$ROOT/evidence/herdr-agents.json" 2>&1
    python3 - "$ROOT/evidence/herdr-agents.json" "$ROOT/evidence" "$CITY_NAME" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

agents_path, evidence_path, session = sys.argv[1:]
evidence = pathlib.Path(evidence_path)
try:
    agents = json.loads(pathlib.Path(agents_path).read_text(encoding="utf-8"))["result"]["agents"]
except (KeyError, OSError, ValueError):
    agents = []
for agent in agents:
    pane_id = agent.get("pane_id")
    if not pane_id:
        continue
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", agent.get("name") or pane_id)
    try:
        result = subprocess.run(
            ["herdr", "--session", session, "pane", "read", pane_id,
             "--source", "recent-unwrapped", "--lines", "300", "--format", "text"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
            text=True,
        )
        output = result.stdout
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or "") + "\nPANE READ TIMED OUT\n"
    (evidence / f"pane-{name}.txt").write_text(output, encoding="utf-8")
PY
    local herdr_config_root
    if [[ -n "${HERDR_CONFIG_PATH:-}" ]]; then
      herdr_config_root="$(dirname "$HERDR_CONFIG_PATH")"
    else
      herdr_config_root="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
    fi
    if [[ -f "$herdr_config_root/sessions/$CITY_NAME/herdr-server.log" ]]; then
      cp "$herdr_config_root/sessions/$CITY_NAME/herdr-server.log" "$ROOT/evidence/herdr-server.log"
    fi
  fi
  if [[ -n "$WORKFLOW_ID" && -f "$CITY/city.toml" ]]; then
    timeout 20 "$GC_BIN_PATH" bd --city "$CITY" --rig probe show "$WORKFLOW_ID" --json > "$ROOT/evidence/root.json" 2>&1
    timeout 20 "$GC_BIN_PATH" bd --city "$CITY" --rig probe list --all --json > "$ROOT/evidence/beads.json" 2>&1
    timeout 20 "$GC_BIN_PATH" --city "$CITY" session list --json > "$ROOT/evidence/sessions.json" 2>&1
    timeout 20 "$GC_BIN_PATH" --city "$CITY" status --format json > "$ROOT/evidence/status.json" 2>&1
    python3 - "$ROOT/evidence/beads.json" "$ROOT/evidence/workflow-diagnostics.json" <<'PY'
import json
import pathlib
import sys

issues = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
by_id = {issue["id"]: issue for issue in issues}
rows = []
for issue in issues:
    if issue.get("status") == "closed":
        continue
    metadata = issue.get("metadata") or {}
    blockers = []
    for dependency in issue.get("dependencies") or []:
        if dependency.get("type") != "blocks":
            continue
        blocker = by_id.get(dependency.get("depends_on_id"), {})
        if blocker.get("status") != "closed":
            blockers.append({
                "id": blocker.get("id"),
                "title": blocker.get("title"),
                "status": blocker.get("status"),
                "step_ref": (blocker.get("metadata") or {}).get("gc.step_ref"),
            })
    rows.append({
        "id": issue.get("id"),
        "title": issue.get("title"),
        "status": issue.get("status"),
        "kind": metadata.get("gc.kind"),
        "step_ref": metadata.get("gc.step_ref"),
        "routed_to": metadata.get("gc.execution_routed_to") or metadata.get("gc.routed_to"),
        "outcome": metadata.get("gc.outcome"),
        "error": metadata.get("gc.controller_error") or metadata.get("gc.failure_reason"),
        "runnable": not blockers,
        "blockers": blockers,
    })
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "runnable_open": [row for row in rows if row["runnable"]],
    "blocked_open": [row for row in rows if not row["runnable"]],
}, indent=2) + "\n", encoding="utf-8")
PY
  fi
  set -e
}

cleanup() {
  local code=$?
  trap - EXIT
  capture_evidence
  if [[ "$START_ATTEMPTED" == "1" ]]; then
    if [[ "$SUPERVISOR_UNIT" == gascity-supervisor-gc-home-*.service ]]; then
      GC_SUPERVISOR_SYSTEMD_UNIT="$SUPERVISOR_UNIT" GC_SUPERVISOR_SYSTEMD_SCOPE=user \
        "$GC_BIN_PATH" supervisor stop --wait --wait-timeout 30s >/dev/null 2>&1 || true
      systemctl --user disable "$SUPERVISOR_UNIT" >/dev/null 2>&1 || true
      systemctl --user kill --kill-whom=all --signal=KILL "$SUPERVISOR_UNIT" >/dev/null 2>&1 || true
    else
      "$GC_BIN_PATH" supervisor stop --wait --wait-timeout 30s >/dev/null 2>&1 || true
    fi
    "$GC_BIN_PATH" supervisor uninstall >/dev/null 2>&1 || true
  fi
  if command -v herdr >/dev/null 2>&1 && \
    herdr --session "$CITY_NAME" status server --json 2>/dev/null | \
      python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("running") else 1)'; then
    herdr session stop "$CITY_NAME" >/dev/null 2>&1 || true
  fi
  kill_root_processes TERM
  sleep 1
  kill_root_processes KILL
  local production_after
  production_after="$(ss -ltnp "sport = :$PRODUCTION_PORT" || true)"
  printf '%s\n' "$PRODUCTION_BEFORE" > "$ROOT/evidence/production-before.txt"
  printf '%s\n' "$production_after" > "$ROOT/evidence/production-after.txt"
  if [[ "$PRODUCTION_BEFORE" != "$production_after" ]]; then
    printf 'production port %s listener changed\n' "$PRODUCTION_PORT" > "$ROOT/evidence/production-listener-failure.txt"
    code=1
  fi
  if [[ "$PACK_LOCAL" == "1" && -n "$PACK_REPO_ROOT" ]]; then
    local pack_commit_after pack_status_after
    pack_commit_after="$(git -C "$PACK_REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
    pack_status_after="$(git -C "$PACK_REPO_ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
    if [[ "$pack_commit_after" != "$PACK_COMMIT" || "$pack_status_after" != "$PACK_STATUS_BEFORE" ]]; then
      printf 'local pack source changed during probe\n' > "$ROOT/evidence/pack-source-failure.txt"
      code=1
    fi
    if [[ -n "$PACK_SOURCE_HASH_BEFORE" ]]; then
      local pack_source_hash_after
      pack_source_hash_after="$(tar -C "$PACK_SOURCE" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - . | sha256sum | awk '{print $1}')"
      if [[ "$pack_source_hash_after" != "$PACK_SOURCE_HASH_BEFORE" ]]; then
        printf 'exported pack source changed during probe\n' > "$ROOT/evidence/pack-export-failure.txt"
        code=1
      fi
    fi
  fi
  if [[ "$KEEP_ROOT" == "0" ]]; then
    rm -rf "$ROOT"
  else
    log "probe retained: $ROOT"
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 124' TERM INT
for command in git grep pgrep python3 readlink sha256sum ss tar timeout; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
command -v "$GC_BIN" >/dev/null 2>&1 || die "missing gc binary: $GC_BIN"
GC_BIN_PATH="$(command -v "$GC_BIN")"
GC_BIN_CANONICAL="$(readlink -f "$GC_BIN_PATH")"
[[ "$CITY_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid disposable city name: $CITY_NAME"
mkdir -p "$ROOT" "$GC_HOME" "$RIG" "$PROBE_TMP" "$PROBE_BIN_DIR"
ln "$GC_BIN_CANONICAL" "$PROBE_BIN_DIR/gc"
export PATH="$PROBE_BIN_DIR:$PATH"
[[ "$(command -v gc)" == "$PROBE_BIN_DIR/gc" && "$PROBE_BIN_DIR/gc" -ef "$GC_BIN_CANONICAL" ]] || \
  die "bare gc does not resolve to probe binary"
GC_BIN_PATH="$PROBE_BIN_DIR/gc"
GC_BIN="$GC_BIN_PATH"

PRODUCTION_BEFORE="$(ss -ltnp "sport = :$PRODUCTION_PORT" || true)"

probe_port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
[[ "$probe_port" != "$PRODUCTION_PORT" ]] || die "allocated production port"
printf '[supervisor]\nport = %s\n' "$probe_port" > "$GC_HOME/supervisor.toml"
export GC_HOME GC_ISOLATED=1 TMPDIR="$PROBE_TMP" PYTHONDONTWRITEBYTECODE=1

log "root=$ROOT port=$probe_port"
run_bounded "$GC_BIN" supervisor status --json | python3 -c '
import json, sys
value = json.load(sys.stdin)
if value.get("running"):
    raise SystemExit("isolated supervisor unexpectedly running")
'

run_bounded "$GC_BIN" init --template gascity --default-provider codex --name "$CITY_NAME" --no-start "$CITY" >/dev/null
if [[ -n "$PACK_PROVENANCE_REPO" ]]; then
  PACK_LOCAL=1
  PACK_REPO_ROOT="$(readlink -f "$PACK_PROVENANCE_REPO")"
  [[ -d "$PACK_REPO_ROOT" ]] || die "pack provenance repository is not a directory: $PACK_REPO_ROOT"
  [[ -n "$PACK_PROVENANCE_SUBDIR" && "$PACK_PROVENANCE_SUBDIR" != /* && "$PACK_PROVENANCE_SUBDIR" != *..* ]] || \
    die "pack provenance subdirectory must be a safe relative path"
  PACK_COMMIT="$(git -C "$PACK_REPO_ROOT" rev-parse HEAD)"
  PACK_STATUS_BEFORE="$(git -C "$PACK_REPO_ROOT" status --porcelain=v1 --untracked-files=all)"
  [[ -z "$PACK_STATUS_BEFORE" ]] || die "pack provenance worktree is dirty: $PACK_REPO_ROOT"
  PACK_VERSION="${GASCITY_PACK_VERSION:-sha:$PACK_COMMIT}"
  [[ "$PACK_VERSION" == "sha:$PACK_COMMIT" ]] || \
    die "pack version $PACK_VERSION differs from provenance HEAD sha:$PACK_COMMIT"
  PACK_SOURCE="$ROOT/pack-source"
  [[ ! -e "$PACK_SOURCE" ]] || die "pack export path already exists: $PACK_SOURCE"
  mkdir -p "$PACK_SOURCE"
  git -C "$PACK_REPO_ROOT" archive "$PACK_COMMIT:$PACK_PROVENANCE_SUBDIR" | tar -x -C "$PACK_SOURCE"
  PACK_SOURCE_HASH_BEFORE="$(tar -C "$PACK_SOURCE" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - . | sha256sum | awk '{print $1}')"
elif [[ "$PACK_SOURCE" = /* ]]; then
  PACK_LOCAL=1
  PACK_SOURCE="$(readlink -f "$PACK_SOURCE")"
  [[ -d "$PACK_SOURCE" ]] || die "local pack source is not a directory: $PACK_SOURCE"
  PACK_REPO_ROOT="$(git -C "$PACK_SOURCE" rev-parse --show-toplevel 2>/dev/null)" || \
    die "local pack source is not in a Git worktree: $PACK_SOURCE"
  PACK_COMMIT="$(git -C "$PACK_REPO_ROOT" rev-parse HEAD)"
  PACK_STATUS_BEFORE="$(git -C "$PACK_REPO_ROOT" status --porcelain=v1 --untracked-files=all)"
  [[ -z "$PACK_STATUS_BEFORE" ]] || die "local pack source worktree is dirty: $PACK_REPO_ROOT"
  PACK_VERSION="${GASCITY_PACK_VERSION:-sha:$PACK_COMMIT}"
  [[ "$PACK_VERSION" == "sha:$PACK_COMMIT" ]] || \
    die "local pack version $PACK_VERSION differs from source HEAD sha:$PACK_COMMIT"
else
  if [[ -z "${GASCITY_PACK_VERSION:-}" && "$PACK_SOURCE" != "$PACK_REPOSITORY/tree/live/gascity" ]]; then
    die "GASCITY_PACK_VERSION is required when remote pack source and repository/live provenance differ"
  fi
  PACK_VERSION="${GASCITY_PACK_VERSION:-sha:$(run_bounded git ls-remote "$PACK_REPOSITORY" refs/heads/live | python3 -c 'import sys; print(sys.stdin.read().split()[0])')}"
fi
[[ "$PACK_VERSION" != "sha:" ]] || die "could not resolve $PACK_REPOSITORY live branch"
# Pin test cost and pack provenance explicitly. gc init currently seeds the
# upstream main pack and builtin Codex defaults; neither is appropriate for
# fork verification. Remove the generated lock so import install resolves and
# pins the requested live fork rather than retaining the template's old SHA.
python3 - "$CITY/city.toml" "$CITY/pack.toml" "$PACK_SOURCE" "$PACK_VERSION" "$PROVIDER" "$MODEL" "$PROBE_TMP" <<'PY'
import json
import pathlib
import re
import sys

city_path = pathlib.Path(sys.argv[1])
pack_path = pathlib.Path(sys.argv[2])
pack_source = sys.argv[3]
pack_version = sys.argv[4]
provider = sys.argv[5]
model = sys.argv[6]
probe_tmp = sys.argv[7]
city = city_path.read_text(encoding="utf-8")
city = (
    '[session]\nprovider = "herdr"\n\n'
    f'[workspace.env]\nTMPDIR = {json.dumps(probe_tmp)}\n\n'
    + city
)
if provider == "omp":
    city = city.replace('provider = "codex"\n', 'provider = "omp"\n', 1)
    city += (
        '\n[providers.omp]\n'
        'base = "builtin:omp"\n'
        'display_name = "Oh My Pi"\n'
        'command = "omp"\n'
        'path_check = "omp"\n'
        'prompt_mode = "arg"\n'
        'print_args = ["-p"]\n'
        'ready_delay_ms = 0\n'
        'instructions_file = "AGENTS.md"\n'
        'resume_flag = "--resume"\n'
        'resume_style = "flag"\n'
        'supports_hooks = true\n'
        '[providers.omp.option_defaults]\n'
        f'model = "{model}"\n'
        '[[providers.omp.options_schema]]\n'
        'key = "model"\n'
        'label = "Model"\n'
        'type = "select"\n'
        f'default = "{model}"\n'
        '[[providers.omp.options_schema.choices]]\n'
        f'value = "{model}"\n'
        'label = "GPT-5.6 Luna"\n'
        f'flag_args = ["--model", "{model}"]\n'
    )
elif provider == "codex":
    city = city.replace(
        'ready_delay_ms = 0\n',
        'ready_delay_ms = 0\n'
        'args_append = ["--dangerously-bypass-hook-trust"]\n'
        'options_schema_merge = "by_key"\n'
        '[providers.codex.option_defaults]\n'
        f'model = "{model}"\n\n'
        '[[providers.codex.options_schema]]\n'
        'key = "model"\n'
        'label = "Model"\n'
        'type = "select"\n'
        'default = ""\n\n'
        '[[providers.codex.options_schema.choices]]\n'
        f'value = "{model}"\n'
        'label = "GPT-5.6 Luna"\n',
        f'flag_args = ["--model", "{model}"]\n',
        1,
    )
else:
    raise SystemExit(f"unsupported E2E_PROVIDER: {provider}")
city = re.sub(
    r'source = "https://github\.com/gastownhall/gascity-packs/tree/main/gascity/roles"\n'
    r'(?:version = "[^"]+"\n)?',
    f'source = "{pack_source}/roles"\nversion = "{pack_version}"\n',
    city,
)
city_path.write_text(city, encoding="utf-8")

pack = pack_path.read_text(encoding="utf-8")
pack = pack.replace("[imports.gascity]\n", "[imports.gc]\n", 1)
pack = re.sub(
    r'source = "https://github\.com/gastownhall/gascity-packs/tree/main/gascity"\n'
    r'(?:version = "[^"]+"\n)?',
    f'source = "{pack_source}"\nversion = "{pack_version}"\n',
    pack,
)
pack_path.write_text(pack, encoding="utf-8")
PY
rm -f "$CITY/packs.lock"
git -C "$RIG" init -q -b main
git -C "$RIG" config user.name e2e-build-basic
git -C "$RIG" config user.email e2e-build-basic@example.invalid
printf '# build-basic E2E rig\n' > "$RIG/README.md"
cat > "$RIG/task.md" <<'EOF'
# Task

Create repository-root `greeting.txt` containing exactly `Hello.` followed by one LF newline.
Commit that file locally with subject exactly `Add repository greeting`. Do not push, publish, or open a pull request.
EOF
printf '%s\n' \
  'items:' \
  '  - name: greeting-task' \
  '    path: task.md' \
  '    description: Exact local greeting-file task and publication constraints.' \
  > "$RIG/context.yaml"
git -C "$RIG" add README.md task.md context.yaml
git -C "$RIG" commit -qm 'Initialize build-basic E2E rig'

run_bounded "$GC_BIN" --city "$CITY" import install >/dev/null
run_bounded "$GC_BIN" --city "$CITY" rig add "$RIG" --name probe --prefix "$RIG_PREFIX" >/dev/null
python3 - "$CITY/city.toml" "$CITY/pack.toml" "$CITY/packs.lock" "$PACK_SOURCE" "$PACK_VERSION" "$PROVIDER" "$MODEL" "$RIG_PREFIX" "$PROBE_TMP" "$PACK_LOCAL" <<'PY'
import pathlib
import sys
import tomllib

city_path, pack_path, lock_path = map(pathlib.Path, sys.argv[1:4])
pack_source, pack_version, provider, model, rig_prefix, probe_tmp = sys.argv[4:10]
pack_local = sys.argv[10] == "1"
role_agents = (
    "design-author",
    "design-implementation-reviewer",
    "design-test-risk-reviewer",
    "gap-analyst",
    "implementation-reviewer",
    "implementation-worker",
    "issue-triager",
    "publisher",
    "requirements-planner",
    "review-synthesizer",
    "run-operator",
    "task-decomposer",
)
with city_path.open("a", encoding="utf-8") as stream:
    for agent in role_agents:
        stream.write(
            "\n[[rigs.patches]]\n"
            f'agent = "{agent}"\n'
            f'provider = "{provider}"\n'
            f'option_defaults = {{ model = "{model}" }}\n'
        )
with city_path.open("rb") as stream:
    city = tomllib.load(stream)
with pack_path.open("rb") as stream:
    pack = tomllib.load(stream)
with lock_path.open("rb") as stream:
    lock = tomllib.load(stream)

assert city["workspace"]["provider"] == provider
assert city["providers"][provider]["option_defaults"]["model"] == model
model_options = [
    option
    for option in city["providers"][provider]["options_schema"]
    if option.get("key") == "model"
]
assert len(model_options) == 1, model_options
model_choices = [
    choice
    for choice in model_options[0]["choices"]
    if choice.get("value") == model
]
assert model_choices == [{
    "value": model,
    "label": "GPT-5.6 Luna",
    "flag_args": ["--model", model],
}], model_choices
if provider == "codex":
    assert city["providers"]["codex"]["options_schema_merge"] == "by_key"
    assert city["providers"]["codex"]["args_append"] == ["--dangerously-bypass-hook-trust"]
else:
    assert city["providers"]["omp"]["base"] == "builtin:omp"
    assert city["providers"]["omp"]["command"] == "omp"
    assert city["providers"]["omp"]["supports_hooks"] is True
assert city["session"]["provider"] == "herdr"
assert city["workspace"]["env"]["TMPDIR"] == probe_tmp
assert city["defaults"]["rig"]["imports"]["gc"]["version"] == pack_version
assert city["rigs"][0]["imports"]["gc"]["version"] == pack_version
assert city["rigs"][0]["prefix"] == rig_prefix
assert city["defaults"]["rig"]["imports"]["gc"]["source"] == f"{pack_source}/roles"
assert city["rigs"][0]["imports"]["gc"]["source"] == f"{pack_source}/roles"
pack_imports = [
    (binding, spec)
    for binding, spec in pack["imports"].items()
    if spec.get("source") == pack_source and spec.get("version") == pack_version
]
assert len(pack_imports) == 1, pack_imports
assert pack_imports[0][0] == "gc", pack_imports
if pack_local:
    assert pack_source not in lock["packs"]
    assert f"{pack_source}/roles" not in lock["packs"]
else:
    assert pack_source in lock["packs"]
    assert f"{pack_source}/roles" in lock["packs"]
PY
hook_help="$(run_bounded "$GC_BIN_PATH" hook --help)"
[[ "$hook_help" == *"--claim"* ]] || die "native hook claim is unavailable"
log "provider=$PROVIDER model=$MODEL pack=$PACK_SOURCE"
if [[ "$CONFIG_ONLY" == "1" ]]; then
  log 'PASS: configuration resolved'
  exit 0
fi
START_ATTEMPTED=1
log 'starting isolated city'
run_bounded "$GC_BIN" --city "$CITY" start "$CITY" >/dev/null
SUPERVISOR_PID="$(run_bounded "$GC_BIN" --city "$CITY" supervisor status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])')"
[[ "$SUPERVISOR_PID" =~ ^[0-9]+$ && -r "/proc/$SUPERVISOR_PID/cgroup" ]] || \
  die "invalid isolated supervisor PID: $SUPERVISOR_PID"
SUPERVISOR_UNIT="$(awk -F: '$1 == "0" { sub(".*/", "", $3); print $3 }' "/proc/$SUPERVISOR_PID/cgroup")"
[[ "$SUPERVISOR_UNIT" == gascity-supervisor-gc-home-*.service ]] || \
  die "isolated supervisor is not in expected systemd unit: $SUPERVISOR_UNIT"
tr '\0' '\n' < "/proc/$SUPERVISOR_PID/environ" | grep -Fxq "GC_HOME=$GC_HOME" || \
  die "isolated supervisor GC_HOME mismatch"
config_explain="$(run_bounded "$GC_BIN" --city "$CITY" config explain --rig probe)"
for target in probe/gc.run-operator probe/gc.requirements-planner probe/gc.implementation-worker; do
  grep -Fq "Agent: $target" <<<"$config_explain" || die "missing scoped target: $target"
done
log 'scoped targets resolved'

log 'creating probe task'
create_output="$(run_bounded "$GC_BIN" bd --city "$CITY" --rig probe create \
  'Create greeting.txt containing exactly Hello. plus newline and commit it as Add repository greeting' \
  --description 'Add greeting.txt containing exactly Hello. Do not push, publish, or open a PR.')"
TASK_ID="$(python3 -c 'import re,sys; prefix=re.escape(sys.argv[1]); value=re.search(r"\b("+prefix+r"-[a-z0-9]+)\b",sys.stdin.read()); print(value.group(1) if value else "")' "$RIG_PREFIX" <<<"$create_output")"
[[ -n "$TASK_ID" ]] || die "could not parse task ID: $create_output"

sling_json="$(run_bounded "$GC_BIN" --city "$CITY" --rig probe sling probe/gc.run-operator "$TASK_ID" \
  --on build-basic --var artifact_root=plans/probe/build \
  --var context_path="$RIG/context.yaml" \
  --var interaction_mode=headless --json)"
WORKFLOW_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["workflow_id"])' <<<"$sling_json")"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "task=$TASK_ID workflow=$WORKFLOW_ID"

status=""
root_json=""
workflow_started_seconds=$SECONDS
deadline=$((SECONDS + TIMEOUT_SECONDS))
last_status=""
while (( SECONDS < deadline )); do
  root_json="$(run_bounded "$GC_BIN" bd --city "$CITY" --rig probe show "$WORKFLOW_ID" --json)" || \
    die "workflow status command exceeded ${COMMAND_TIMEOUT_SECONDS}s or failed"
  status="$(python3 -c 'import json,sys; value=json.load(sys.stdin); value=value[0] if isinstance(value,list) else value; print(value["status"])' <<<"$root_json")"
  if [[ "$status" != "$last_status" ]]; then
    log "workflow status=$status elapsed=$((SECONDS - workflow_started_seconds))s"
    last_status="$status"
  else
    log "workflow heartbeat status=$status elapsed=$((SECONDS - workflow_started_seconds))s"
  fi
  case "$status" in
    closed|failed|cancelled) break ;;
  esac
  sleep "$POLL_SECONDS"
done
if [[ "$status" != "closed" && "$status" != "failed" && "$status" != "cancelled" ]]; then
  capture_evidence
  die "workflow remained $status after ${TIMEOUT_SECONDS}s; diagnostics: $ROOT/evidence/workflow-diagnostics.json"
fi
run_bounded "$GC_BIN" bd --city "$CITY" --rig probe list --all --json > "$ROOT/evidence/beads.json"
run_bounded "$GC_BIN" --city "$CITY" session list --json > "$ROOT/evidence/sessions.json" || true
run_bounded "$GC_BIN" --city "$CITY" status --format json > "$ROOT/evidence/status.json" || true
run_bounded "$GC_BIN" --city "$CITY" events --since "${TIMEOUT_SECONDS}s" > "$ROOT/evidence/events.txt" || true
cp "$GC_HOME/supervisor.log" "$ROOT/evidence/supervisor.log" 2>/dev/null || true

analysis="$(python3 - "$ROOT/evidence/beads.json" "$WORKFLOW_ID" <<'PY'
import json
import sys

issues = json.load(open(sys.argv[1], encoding="utf-8"))
root_id = sys.argv[2]
root_ids = {root_id}
while True:
    relevant = []
    for issue in issues:
        metadata = issue.get("metadata") or {}
        if issue.get("id") in root_ids or root_ids.intersection({
            metadata.get("gc.root_bead_id"),
            metadata.get("gc.workflow_root_id"),
            metadata.get("gc.workflow_id"),
        }):
            relevant.append(issue)
    discovered = set()
    for issue in relevant:
        metadata = issue.get("metadata") or {}
        manifest = metadata.get("gc.drain_manifest.v1")
        if not manifest:
            continue
        try:
            value = json.loads(manifest)
        except (TypeError, ValueError):
            continue
        for row in value.get("rows", []):
            if isinstance(row, dict) and row.get("item_root_id"):
                discovered.add(row["item_root_id"])
    if discovered <= root_ids:
        break
    root_ids.update(discovered)

failures = []
for issue in relevant:
    metadata = issue.get("metadata") or {}
    if metadata.get("gc.outcome") == "fail" or metadata.get("gc.controller_error"):
        failures.append({
            "id": issue.get("id"),
            "title": issue.get("title"),
            "status": issue.get("status"),
            "kind": metadata.get("gc.kind"),
            "step_ref": metadata.get("gc.step_ref"),
            "error": metadata.get("gc.controller_error") or metadata.get("gc.failure_reason"),
            "disposition": metadata.get("gc.final_disposition"),
        })

print(json.dumps({
    "workflow_root_ids": sorted(root_ids),
    "relevant_count": len(relevant),
    "failures": failures,
}, indent=2))
PY
)"
printf '%s\n' "$analysis" > "$ROOT/evidence/analysis.json"

if [[ "$status" != "closed" ]]; then
  printf '%s\n' "$analysis" >&2
  die "workflow $WORKFLOW_ID did not close naturally; status=$status"
fi

root_outcome="$(python3 -c '
import json,sys
value=json.load(sys.stdin); value=value[0] if isinstance(value,list) else value
print((value.get("metadata") or {}).get("gc.outcome", ""))
' <<<"$root_json")"
[[ "$root_outcome" == "pass" ]] || die "workflow closed without gc.outcome=pass"

failure_count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["failures"]))' <<<"$analysis")"
[[ "$failure_count" == "0" ]] || die "workflow graph contains $failure_count failed or quarantined control beads"

finalizer_count="$(python3 - "$ROOT/evidence/beads.json" "$WORKFLOW_ID" <<'PY'
import json, sys
issues = json.load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]
print(sum(
    1 for issue in issues
    if (issue.get("metadata") or {}).get("gc.kind") == "workflow-finalize"
    and (issue.get("metadata") or {}).get("gc.root_bead_id") == root
    and issue.get("status") == "closed"
    and (issue.get("metadata") or {}).get("gc.outcome") == "pass"
))
PY
)"
[[ "$finalizer_count" -ge 1 ]] || die "no naturally closed workflow-finalize bead"


artifact_dir="$(python3 - "$RIG" <<'PY'
import pathlib
import sys

required = {
    "requirements.md",
    "implementation-plan.md",
    "decomposition.md",
    "review-report.md",
    "factory-run.md",
}
for candidate in pathlib.Path(sys.argv[1]).rglob("plans/probe/build"):
    if candidate.is_dir() and required <= {path.name for path in candidate.iterdir() if path.is_file()}:
        print(candidate)
        break
PY
)"
[[ -n "$artifact_dir" ]] || die "complete plans/probe/build artifact set missing"
for artifact in requirements.md implementation-plan.md decomposition.md review-report.md factory-run.md; do
  grep -Fq 'greeting.txt' "$artifact_dir/$artifact" || die "$artifact does not trace greeting.txt"
done

workspace_state="$(python3 - "$RIG/.git" "$ROOT/evidence/analysis.json" <<'PY'
import json
import pathlib
import sys

state_root = pathlib.Path(sys.argv[1]) / "gc-workspace-state"
workflow_root_ids = set(json.load(open(sys.argv[2], encoding="utf-8"))["workflow_root_ids"])
for candidate in state_root.rglob("*.json"):
    try:
        state = json.loads(candidate.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        continue
    if state.get("workflow_root_id") in workflow_root_ids:
        print(candidate)
        break
PY
)"
[[ -n "$workspace_state" ]] || die "workspace state missing"
python3 - "$workspace_state" <<'PY'
import json
import pathlib
import subprocess
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
required = {
    "version", "workflow_root_id", "source_anchor_id", "host_id",
    "common_git_dir", "worktree_path", "input_oid", "phase", "output_oid",
}
if set(value) != required or value.get("version") != 1:
    raise SystemExit("workspace state schema is invalid")
if value.get("phase") != "result" or not value.get("input_oid") or not value.get("output_oid"):
    raise SystemExit("workspace lifecycle did not reach result")
worktree = pathlib.Path(value["worktree_path"])
if not worktree.is_dir() or worktree.is_symlink():
    raise SystemExit("recorded workspace path is invalid")

def git(*args):
    return subprocess.run(
        ["git", "-C", str(worktree), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.strip()

if git("rev-parse", "HEAD") != value["output_oid"]:
    raise SystemExit("workspace HEAD differs from output_oid")
if value["input_oid"] == value["output_oid"]:
    raise SystemExit("workspace produced no implementation commit")
if git("log", "-1", "--format=%s", value["output_oid"]) != "Add repository greeting":
    raise SystemExit("result commit subject is not exactly Add repository greeting")
changed_paths = git("diff", "--name-only", value["input_oid"], value["output_oid"]).splitlines()
if changed_paths != ["greeting.txt"]:
    raise SystemExit(f"result commit must change only repository-root greeting.txt: {changed_paths}")
greeting = subprocess.run(
    ["git", "-C", str(worktree), "show", f'{value["output_oid"]}:greeting.txt'],
    check=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
).stdout
if greeting != b"Hello.\n":
    raise SystemExit("result commit greeting.txt is not exact Hello.\\n")
subprocess.run(
    ["git", "-C", str(worktree), "merge-base", "--is-ancestor", value["input_oid"], value["output_oid"]],
    check=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
if git("status", "--porcelain=v1", "--untracked-files=all"):
    raise SystemExit("result workspace is dirty")
PY

log "PASS: workflow=$WORKFLOW_ID root=$ROOT"
