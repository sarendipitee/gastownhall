# Gastownhall - Live E2E Harness

This repository provides the live e2e harness for a Gas City deployment. It allows you to run a full round-trip live test, including standing up a local Gas City supervisor, evaluating a Sarendipitee pack, and running integration probes.

## Prerequisites

To run this harness, you need the following installed:

- **Go Toolchain** (1.20+)
- **Git**
- **tmux**
- **Python 3**
- **Dolt** (available on your `PATH`)
- **DoltLite Native Library** + **sqlite3 dev headers**: 
  The setup expects the DoltLite native lib to be present. By default, it expects the path to be `$HOME/.local/lib/doltlite-0.11.23` (via the `DOLTLITE_ROOT` environment variable). You must have this installed locally before building system binaries.
- **Model Provider Auth**: The `e2e-build-basic.sh` script relies on a model API for evaluating behavior (`E2E_CODEX_MODEL`). You will need the appropriate authentication configured for your chosen model provider (set via the necessary provider-specific secret environment variables). Do not commit any secrets.

## Obtaining the Components

The Gastownhall workspace is a meta-repository. The 6 core components are tracked as git submodules.

To fetch them at their pinned, known-good commits, simply initialize the submodules:

```bash
git submodule update --init --recursive
```

Alternatively, you can run the provided setup script:

```bash
./scripts/setup.sh
```

## Quick Start

1. **Setup the workspace:**
   ```bash
   ./scripts/setup.sh
   ```

2. **Build and install system binaries (`gc`, `bd`, etc.):**
   ```bash
   ./scripts/rebuild-system-bins.sh
   ```
   *(Ensure your `DOLTLITE_ROOT` is correct and you have sqlite headers)*

3. **Run the local city smoke test:**
   ```bash
   ./scripts/smoke-local-city.sh
   ```

4. **Run the full e2e basic probe:**
   ```bash
   # Set E2E_CODEX_MODEL and credentials as needed
   ./scripts/e2e-build-basic.sh
   ```
