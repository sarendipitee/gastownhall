# Gastownhall Workspace Policy

## Component Layout

- Every component parent uses `<repo>/.git` as bare shared Git metadata. Do not check out or work in `<repo>/` itself.
- Each component worktree is a direct child of its parent and has a named branch. `<repo>/main` is the integration and sync base on branch `main`; `<repo>/live` is deployment integration on branch `live`.
- Start new work from `<repo>/main`. Create feature or fix worktrees directly under `<repo>/` with their branch name; do not nest them under `work/`.
- `main` is disposable sync base: keep it close to `upstream/main`, reset it to `upstream/main` when appropriate, force-push it only as workspace policy permits, and do not commit feature, fix, or merge work directly on it.
- Reserve `live` for deployment-bound merges, promotion work, and final binary rollout preparation. Do not use `live` as default base for new development work.
- `<repo>/work/` is forbidden, including stale legacy directories.
- `<city>/.gc/worktrees/...` is external City runtime state, unrelated to component worktrees. Do not move, rename, or treat it as component layout.

## Practical Rules

- Before branching new work, it is normal to hard-reset `<repo>/main` to `upstream/main` and force-push `origin/main` to match.
- If a repository does not have a remote `live` branch, keep a local `live` branch so workspace layout stays consistent.
- Keep both `<repo>/main` and `<repo>/live` clean unless actively working in them for their intended purpose.

## Live SOP Scripts

- Run `scripts/live-status.sh` before and after live promotion work.
- `scripts/live-status.sh` reports `main` and `live` branches, status, and HEAD commits from child checkouts, installed `gc`/DoltLite plugin binaries, supervisor state, `~/city` status, and beads health.
- Run `scripts/assert-live-layout.sh` before handing off live work.
- `scripts/assert-live-layout.sh` must pass unless intentionally mid-operation. It validates bare component Git metadata, direct `<repo>/main` on `main`, direct `<repo>/live` on `live`, and live cleanliness; it also requires `gc` and DoltLite plugin binaries built with `libsqlite3,gms_pure_go`.
- Treat script failures as deployment blockers until verified and either fixed or explicitly documented in handoff.
- Use `scripts/sling-update-forks.sh` to create per-rig fork-update beads instead of manually telling multiple agents to fetch/rebase/merge.
- Default fork-update rigs are `gascity-source`, `gascity-packs-source`, `gascity-dashboard`, `beads-source`, and `beads-backend-doltlite-source`.
- `scripts/sling-update-forks.sh` is dry-run by default. Use `--apply` to create beads and sling them with `gc sling <rig>/gastown.polecat <bead> --on mol-polecat-work`.
- `scripts/sling-update-forks.sh --apply` runs `live-status.sh` and `assert-live-layout.sh` first, and refuses to proceed on layout failure unless `--allow-layout-fail` is passed.
