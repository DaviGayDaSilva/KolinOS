#!/usr/bin/env bash
# make-source-zip.sh — package the KolinOS source tree into a distributable ZIP.
#
# Usage: make-source-zip.sh [OUTPUT_DIR]   (default: ./output)
set -euo pipefail

SHORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SHORT_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"
KOLIN_CODENAME_LOWER="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"
OUT="${1:-$ROOT/output}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

have() { command -v "$1" >/dev/null 2>&1; }
have zip || { echo "[zip][erro] 'zip' não instalado (Debian: apt install zip)" >&2; exit 1; }

NAME="kolinos-source-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}"
ZIP="$OUT/${NAME}.zip"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-zip.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Copy the tree, excluding generated/heavy/VCS content.
mkdir -p "$STAGE/$NAME"
tar -C "$ROOT" \
    --exclude='./.git' \
    --exclude='./rootfs' \
    --exclude='./output' \
    --exclude='./repo/public' \
    --exclude='./repo/keys' \
    --exclude='*.tar.xz' \
    --exclude='*.iso' \
    -cf - . | tar -C "$STAGE/$NAME" -xf -

rm -f "$ZIP"
# Reproducible: fixed mtimes inside the ZIP as well (source archives too).
STAMP="${KOLIN_BUILD_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date -u +%s)}"
find "$STAGE" -exec touch -h -d "@$STAMP" {} + 2>/dev/null || true
( cd "$STAGE" && zip -qr -X "$ZIP" "$NAME" )
SUM="$(sha256sum "$ZIP" | awk '{print $1}')"
: > "$OUT/SOURCE-SHA256SUMS"
echo "$SUM  $(basename "$ZIP")" >> "$OUT/SOURCE-SHA256SUMS"
echo "[zip] $ZIP ($(du -h "$ZIP" | awk '{print $1}'))"
echo "[zip] sha256: $SUM"
