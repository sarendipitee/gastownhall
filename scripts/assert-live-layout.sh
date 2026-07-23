#!/usr/bin/env bash
set -euo pipefail

ROOT="${GASTOWNHALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
failures=0

repos=(
  gascity
  gascity-packs
  gascity-dashboard
  beads
  beads-backend-doltlite
)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

ok() {
  printf 'OK: %s\n' "$*"
}
canonical_dir() {
  cd "$1" && pwd -P
}

require_exact_config() {
  local config_file="$1" key="$2" want="$3" label="$4" value
  if ! value="$(git config --file "$config_file" --get "$key" 2>/dev/null)"; then
    fail "$label missing $key"
  elif [[ "$value" == "$want" ]]; then
    ok "$label $key is $want"
  else
    fail "$label $key is $value; want $want"
  fi
}

require_bare_metadata() {
  local git_dir="$1" label="$2" bare
  if ! bare="$(git --git-dir="$git_dir" rev-parse --is-bare-repository 2>/dev/null)"; then
    fail "$label cannot determine whether $git_dir is bare"
  elif [[ "$bare" == true ]]; then
    ok "$label shared Git metadata is bare"
  else
    fail "$label shared Git metadata is not bare"
  fi
}
require_direct_child_worktrees() {
  local repo_dir="$1" git_dir="$2" label="$3" parent worktree_list line registered_worktree canonical_worktree relative_worktree
  if ! parent="$(canonical_dir "$repo_dir")"; then
    fail "$label cannot canonicalize component parent $repo_dir"
    return
  fi
  if ! worktree_list="$(git --git-dir="$git_dir" worktree list --porcelain 2>/dev/null)"; then
    fail "$label cannot list registered worktrees"
    return
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "worktree "* ]] || continue
    registered_worktree="${line#worktree }"
    if ! canonical_worktree="$(canonical_dir "$registered_worktree")"; then
      fail "$label cannot canonicalize registered worktree $registered_worktree"
      continue
    fi
    if [[ "$canonical_worktree" == "$parent" || "$canonical_worktree" != "$parent/"* ]]; then
      continue
    fi
    relative_worktree="${canonical_worktree#"$parent/"}"
    if [[ "$relative_worktree" == */* ]]; then
      fail "$label registered local worktree is nested: $canonical_worktree"
    fi
  done <<< "$worktree_list"
}


require_worktree_binding() {
  local worktree="$1" git_dir="$2" label="$3" top_level common_dir expected_top_level expected_common_dir
  if [[ ! -d "$worktree" ]]; then
    fail "$label missing worktree at $worktree"
    return
  fi
  if ! top_level="$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)"; then
    fail "$label cannot resolve Git top-level"
    return
  fi
  if ! common_dir="$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null)"; then
    fail "$label cannot resolve common Git directory"
    return
  fi
  if ! top_level="$(canonical_dir "$top_level")"; then
    fail "$label Git top-level is not a directory"
    return
  fi
  if ! common_dir="$(cd "$worktree" && canonical_dir "$common_dir")"; then
    fail "$label common Git directory is not a directory"
    return
  fi
  expected_top_level="$(canonical_dir "$worktree")"
  expected_common_dir="$(canonical_dir "$git_dir")"
  if [[ "$top_level" == "$expected_top_level" ]]; then
    ok "$label Git top-level is its direct child worktree"
  else
    fail "$label Git top-level is $top_level; want $expected_top_level"
  fi
  if [[ "$common_dir" == "$expected_common_dir" ]]; then
    ok "$label common Git directory is parent .git"
  else
    fail "$label common Git directory is $common_dir; want $expected_common_dir"
  fi
}


require_branch() {
  local dir="$1" want="$2" label="$3" branch
  branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
  if [[ "$branch" == "$want" ]]; then
    ok "$label branch is $want"
  else
    fail "$label branch is ${branch:-detached/unknown}; want $want"
  fi
}

require_clean() {
  local dir="$1" label="$2" status
  if ! status="$(git -C "$dir" status --porcelain 2>/dev/null)"; then
    fail "$label status query failed"
    return
  fi
  if [[ -z "$status" ]]; then
    ok "$label clean"
  else
    fail "$label dirty"
    git -C "$dir" status --short >&2 || true
  fi
}

for repo in "${repos[@]}"; do
  repo_dir="$ROOT/$repo"
  git_dir="$repo_dir/.git"
  main_dir="$repo_dir/main"
  live_dir="$repo_dir/live"

  if [[ ! -d "$git_dir" ]]; then
    fail "$repo missing shared Git metadata directory at $git_dir"
    continue
  fi

  require_bare_metadata "$git_dir" "$repo"
  require_exact_config "$git_dir/config" extensions.worktreeConfig true "$repo shared config"
  require_direct_child_worktrees "$repo_dir" "$git_dir" "$repo"


  if [[ -e "$repo_dir/work" || -L "$repo_dir/work" ]]; then
    fail "$repo contains forbidden legacy work directory at $repo_dir/work"
  else
    ok "$repo has no legacy work directory"
  fi

  require_worktree_binding "$main_dir" "$git_dir" "$repo main"
  if [[ -d "$main_dir" ]]; then
    require_branch "$main_dir" main "$repo main"
  fi

  require_worktree_binding "$live_dir" "$git_dir" "$repo live"
  if [[ -d "$live_dir" ]]; then
    require_branch "$live_dir" live "$repo live"
    require_clean "$live_dir" "$repo live"
  fi
done

if command -v gc >/dev/null 2>&1; then
  ok "gc on PATH: $(command -v gc)"
else
  fail "gc missing from PATH"
fi

for bin in bd-backend-doltlite gc-doltlite-fastpath; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    fail "$bin missing from PATH"
    continue
  fi
  if go version -m "$(command -v "$bin")" 2>/dev/null | grep -q 'build[[:space:]]\+-tags=.*libsqlite3.*gms_pure_go'; then
    ok "$bin built with libsqlite3,gms_pure_go"
  else
    fail "$bin missing libsqlite3,gms_pure_go build tags"
  fi
done

if (( failures > 0 )); then
  printf '\n%d live layout check(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nLive layout checks passed.\n'
