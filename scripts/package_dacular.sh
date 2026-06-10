#!/usr/bin/env bash
#
# Build dacular.zip — the dacular source bundle the Millrace app downloads, then
# `mojo build`s on-device against a separately-fetched Mojo compiler (see
# millrace/app Bootstrapper). Mirrors headgate/scripts/package_headgate.sh, but
# dacular currently has NO FFI shims or sibling-repo deps, so the bundle is just
# the source + pixi.toml and the app builds it with a bare:
#
#   (cd dacular && mojo build src/dacular.mojo -o build/dacular)
#
# Usage: scripts/package_dacular.sh [out.zip]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dacular.zip}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac   # zip runs from a temp dir — need absolute

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/dacular"

echo "==> staging dacular source" >&2
mkdir -p "$D"
cp -R "$ROOT/src" "$D/src"
cp "$ROOT/pixi.toml" "$D/pixi.toml"
[[ -f "$ROOT/pixi.lock" ]] && cp "$ROOT/pixi.lock" "$D/pixi.lock"

echo "==> zipping -> $OUT" >&2
rm -f "$OUT"
( cd "$STAGE" && zip -qr -X "$OUT" dacular )
echo "==> done" >&2
ls -lh "$OUT" >&2
