#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
WORKSPACE_ROOT=$(pwd)

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Verifying DoltLite and SQLite dependencies..."
DOLTLITE_ROOT="${DOLTLITE_ROOT:-$HOME/.local/lib/doltlite-0.11.23}"

if [ ! -d "$DOLTLITE_ROOT" ]; then
    echo "ERROR: DoltLite root not found at $DOLTLITE_ROOT."
    echo "Please install DoltLite and set DOLTLITE_ROOT if it is not in the default location."
    exit 1
fi

if ! [ -f "$DOLTLITE_ROOT/include/doltlite.h" ] || ! [ -f "$DOLTLITE_ROOT/lib/libdoltlite.so" ] && ! [ -f "$DOLTLITE_ROOT/lib/libdoltlite.a" ]; then
    echo "ERROR: DoltLite headers or library not found in $DOLTLITE_ROOT."
    exit 1
fi

# SQLite check
if ! echo -e "#include <sqlite3.h>\nint main(){}" | gcc -xc - -o /dev/null 2>/dev/null; then
    echo "ERROR: sqlite3 development headers not found. Please install them (e.g. apt-get install libsqlite3-dev)."
    exit 1
fi

echo "==> Building and installing system binaries..."
./scripts/rebuild-system-bins.sh

echo "==> Setup complete!"
