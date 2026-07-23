#!/usr/bin/env bash
set -euo pipefail

# Rebuild and install deployment-bound Gastownhall binaries.
# Builds stay staged until every validation gate passes.

ROOT="${GASTOWNHALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DOLTLITE_ROOT="${DOLTLITE_ROOT:-$HOME/.local/lib/doltlite-0.11.23}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
GO_TAGS="${GO_TAGS:-libsqlite3 gms_pure_go}"
GOFLAGS_NO_VCS="${GOFLAGS:--buildvcs=false}"
CC_BIN="${CC:-cc}"

gc_src="${GC_SRC:-$ROOT/gascity/live}"
if [ ! -d "$gc_src" ] && [ -d "$ROOT/gascity" ]; then gc_src="$ROOT/gascity"; fi

bd_src="${BD_SRC:-$ROOT/beads/live}"
if [ ! -d "$bd_src" ] && [ -d "$ROOT/beads" ]; then bd_src="$ROOT/beads"; fi
gc_modfile=""

backend_src="${BACKEND_SRC:-$ROOT/beads-backend-doltlite/live}"
if [ ! -d "$backend_src" ] && [ -d "$ROOT/beads-backend-doltlite" ]; then backend_src="$ROOT/beads-backend-doltlite"; fi

dolt_include="$DOLTLITE_ROOT/include"
dolt_lib="$DOLTLITE_ROOT/lib"

die() {
	printf 'rebuild-system-bins: %s\n' "$*" >&2
	exit 1
}

require_file() {
	[[ -r "$1" ]] || die "missing required file: $1"
}

require_clean() {
	local dir="$1" status
	[[ -d "$dir" ]] || die "missing checkout: $dir"
	status="$(git -C "$dir" status --porcelain 2>/dev/null || true)"
	[[ -z "$status" ]] || die "$dir is dirty"
}

require_file "$dolt_include/doltlite.h"
if [[ ! -r "$dolt_lib/libdoltlite.so" && ! -r "$dolt_lib/libdoltlite.a" ]]; then
	die "DoltLite library missing under $dolt_lib"
fi

require_clean "$gc_src"
require_clean "$bd_src"
require_clean "$backend_src"
[[ -f "$gc_src/Makefile" ]] || die "gc live checkout has no Makefile"
[[ -f "$bd_src/Makefile" ]] || die "bd live checkout has no Makefile"
require_file "$backend_src/go.mod"
require_file "$backend_src/cmd/bd-backend-doltlite/main.go"
require_file "$backend_src/cmd/gc-doltlite-fastpath/main.go"

# libsqlite3 builds need matching compiler headers and linker files. Prefer
# active compiler paths; then discover a complete sqlite dev package in Nix.
sqlite_cflags=""
sqlite_ldflags=""
sqlite_header_ok=0
sqlite_link_dir=""
stage=""
cleanup() {
	[[ -z "$stage" ]] || rm -rf "$stage"
	[[ -z "$sqlite_link_dir" ]] || rm -rf "$sqlite_link_dir"
}
trap cleanup EXIT
if printf '#include <sqlite3.h>\n' | "$CC_BIN" -E -x c - >/dev/null 2>&1; then
	sqlite_header_ok=1
else
	if [[ -d /nix/store ]]; then
		while IFS= read -r sqlite_header; do
			sqlite_prefix="${sqlite_header%/include/sqlite3.h}"
			[[ "$sqlite_prefix" =~ sqlite-([0-9.]+)-dev$ ]] || continue
			sqlite_version="${BASH_REMATCH[1]}"
			sqlite_so="$(find /nix/store -maxdepth 5 -type f -path "*-sqlite-${sqlite_version}/lib/libsqlite3.so.*" -print -quit 2>/dev/null)"
			[[ -n "$sqlite_so" ]] || continue
			sqlite_lib="${sqlite_so%/lib/*}/lib"
			if printf '#include <sqlite3.h>\n' | "$CC_BIN" -E -I"${sqlite_prefix}/include" -x c - >/dev/null 2>&1; then
				sqlite_link_dir="$(mktemp -d "${TMPDIR:-/tmp}/gastownhall-sqlite-link.XXXXXX")"
				ln -s "$sqlite_so" "$sqlite_link_dir/libsqlite3.so"
				sqlite_cflags="-I${sqlite_prefix}/include"
				sqlite_ldflags="-L${sqlite_link_dir} -L${sqlite_lib} -Wl,-rpath,${sqlite_lib}"
				sqlite_header_ok=1
				printf 'using Nix SQLite: headers=%s runtime=%s\n' "$sqlite_prefix" "$sqlite_so"
				break
			fi
		done < <(find /nix/store -maxdepth 4 -type f -path '*/include/sqlite3.h' -print 2>/dev/null | sort)
	fi
fi
((sqlite_header_ok == 1)) ||
	die 'compiler cannot find sqlite3.h; no usable system or Nix SQLite development package found'

stage="$(mktemp -d "${TMPDIR:-/tmp}/gastownhall-system-bins.XXXXXX")"
if [[ "$gc_src" == "$ROOT/gascity/live" && "$bd_src" == "$ROOT/beads/live" ]]; then
	gc_modfile="$stage/gascity-live.mod"
fi
if [[ -n "$gc_modfile" ]]; then
	cp -f "$gc_src/go.mod" "$gc_modfile"
	cp -f "$gc_src/go.sum" "${gc_modfile%.mod}.sum"
	printf '\nreplace github.com/steveyegge/beads => %s\n' "$bd_src" >>"$gc_modfile"
	GOFLAGS="$GOFLAGS_NO_VCS" go -C "$gc_src" mod tidy -modfile="$gc_modfile"
fi
mkdir -p "$stage/gc" "$stage/bd" "$stage/backend"
go_no_vcs() {
	GOFLAGS="$GOFLAGS_NO_VCS" go "$@"
}

gc_beads_version="$(go_no_vcs -C "$gc_src" list -m -f '{{.Version}}' github.com/steveyegge/beads)"
[[ -n "$gc_beads_version" ]] || die 'gc Beads module version is empty'

printf 'building gc from %s\n' "$gc_src"
# buildvcs necessary due to bare layout until Go 1.27 support
env GOFLAGS="$GOFLAGS_NO_VCS" make -C "$gc_src" BUILD_DIR="$stage/gc" GOFLAGS="${GOFLAGS_NO_VCS}${gc_modfile:+ -modfile=$gc_modfile}" check-self-contained

printf 'building bd from %s\n' "$bd_src"
go_no_vcs -C "$bd_src" build -tags gms_pure_go \
	-ldflags "-X main.Version=$gc_beads_version -X main.Build=$(git -C "$bd_src" rev-parse --short HEAD)" \
	-o "$stage/bd/bd" ./cmd/bd

printf 'building DoltLite binaries from %s\n' "$backend_src"
(
	cd "$backend_src"
	backend_cflags="${CGO_CFLAGS:--I$dolt_include} ${sqlite_cflags}"
	backend_ldflags="${CGO_LDFLAGS:--L$dolt_lib -Wl,-rpath,$dolt_lib -ldoltlite -lz -lpthread -lm} ${sqlite_ldflags}"
	GOFLAGS="$GOFLAGS_NO_VCS" \
	CGO_ENABLED=1 \
		CGO_CFLAGS="$backend_cflags" \
		CGO_LDFLAGS="$backend_ldflags" \
		go build -tags "$GO_TAGS" -o "$stage/backend/bd-backend-doltlite" ./cmd/bd-backend-doltlite
	GOFLAGS="$GOFLAGS_NO_VCS" \
	CGO_ENABLED=1 \
		CGO_CFLAGS="$backend_cflags" \
		CGO_LDFLAGS="$backend_ldflags" \
		go build -tags "$GO_TAGS" -o "$stage/backend/gc-doltlite-fastpath" ./cmd/gc-doltlite-fastpath
)

for bin in \
	"$stage/gc/gc" \
	"$stage/bd/bd" \
	"$stage/backend/bd-backend-doltlite" \
	"$stage/backend/gc-doltlite-fastpath"; do
	require_file "$bin"
	chmod 0755 "$bin"
done

if command -v readelf >/dev/null 2>&1; then
	for bin in "$stage/backend/bd-backend-doltlite" "$stage/backend/gc-doltlite-fastpath"; do
		readelf -d "$bin" | grep -qiE 'RUNPATH|RPATH' || die "$bin has no RUNPATH/RPATH"
	done
fi

go version -m "$stage/backend/bd-backend-doltlite" | grep -q 'build.*libsqlite3.*gms_pure_go' ||
	die 'bd-backend-doltlite missing libsqlite3,gms_pure_go build tags'
go version -m "$stage/backend/gc-doltlite-fastpath" | grep -q 'build.*libsqlite3.*gms_pure_go' ||
	die 'gc-doltlite-fastpath missing libsqlite3,gms_pure_go build tags'
env -i HOME="$HOME" PATH=/usr/bin:/bin "$stage/gc/gc" version >/dev/null ||
	die 'gc failed clean-environment boot'
env -i HOME="$HOME" PATH=/usr/bin:/bin \
	"$stage/backend/bd-backend-doltlite" capabilities >/dev/null ||
	die 'bd-backend-doltlite failed clean-environment capabilities check'

mkdir -p "$INSTALL_DIR"
for pair in \
	"$stage/gc/gc:$INSTALL_DIR/gc" \
	"$stage/bd/bd:$INSTALL_DIR/bd" \
	"$stage/backend/bd-backend-doltlite:$INSTALL_DIR/bd-backend-doltlite" \
	"$stage/backend/gc-doltlite-fastpath:$INSTALL_DIR/gc-doltlite-fastpath"; do
	src="${pair%%:*}"
	dst="${pair#*:}"
	tmp="$dst.tmp.$$"
	cp -f "$src" "$tmp"
	chmod 0755 "$tmp"
	mv -f "$tmp" "$dst"
	printf 'installed %s\n' "$dst"
done

ln -s bd "$stage/beads"
mv -Tf "$stage/beads" "$INSTALL_DIR/beads"
printf 'installed %s\n' "$INSTALL_DIR/beads"

printf 'system binary rebuild passed\n'
