# Gastownhall Workspace Policy

## Component Layout

- Every component parent uses `<repo>/.git` as bare shared Git metadata. Do not check out or work in `<repo>/` itself.
- Each component worktree is a direct child of its parent and has a named branch. `<repo>/main` is the integration and sync base on branch `main`; `<repo>/live` is deployment integration on branch `live`.
- Start new work from `<repo>/main`. Create feature or fix worktrees directly under `<repo>/` with their branch name; do not nest them under `work/`.
- `main` is disposable sync base: keep it close to `upstream/main`, reset it to `upstream/main` when appropriate, force-push it only as workspace policy permits, and do not commit feature, fix, or merge work directly on it.
- Reserve `live` for deployment-bound merges, promotion work, and final binary rollout preparation. Do not use `live` as default base for new development work.

## Live History Policy

- `upstream/main` is the immutable base of `live`, never an integration branch. Update `live` to current `upstream/main` by rebasing the complete fork integration stack onto it; NEVER merge `upstream/main` (or a branch that merely copies upstream commits) into `live`, and NEVER cherry-pick upstream commits onto `live`.
- Only feature or fix branches owned by this fork or another contributor fork may be merged into `live`. Preserve those branch boundaries with explicit merge commits so `git log --first-parent live` shows only fork integrations above the upstream base.
- Before merging a fork branch into `live`, rebase that source branch onto current `upstream/main`. If it conflicts with `live`, return to the source branch, rebase or repair it there against current `upstream/main`, verify it, then retry the merge. Do not resolve source-branch compatibility by committing directly on `live`.
- When upstream advances after fork branches have landed, rebase the entire `live` merge topology with merge preservation (for example, `git rebase --rebase-merges --onto <new-upstream> <old-upstream> live`). Confirm the resulting merge base is current `upstream/main` and that no upstream-only commit appears in `upstream/main..live`.
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
