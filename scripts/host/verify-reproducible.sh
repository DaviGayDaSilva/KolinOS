#!/usr/bin/env bash
# verify-reproducible.sh — rebuild the rootfs twice and prove the archives are
# byte-identical. This is the acceptance test for FASE 4.
#
# It builds the full pipeline into two separate output directories with the same
# fixed epoch, then compares SHA-256. Requires root (debootstrap/chroot).
#
# Usage: sudo bash scripts/host/verify-reproducible.sh [--snapshot STAMP]
set -euo pipefail

SHORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SHORT_DIR/../.." && pwd)"

SNAPSHOT="${KOLIN_SNAPSHOT:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot) SNAPSHOT="$2"; shift 2 ;;
        *) echo "uso: verify-reproducible.sh [--snapshot STAMP]" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "precisa de root: sudo bash $0" >&2; exit 1; }

EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date -u +%s)"
A="$ROOT/output/.repro/a"
B="$ROOT/output/.repro/b"
rm -rf "$ROOT/output/.repro"
mkdir -p "$A" "$B"

build_once() { # <output-dir> <rootfs-dir>
    local out="$1" rfs="$2"
    bash "$ROOT/build.sh" --force --no-iso --epoch "$EPOCH" \
        ${SNAPSHOT:+--snapshot "$SNAPSHOT"} \
        --output "$out" --rootfs "$rfs" >/dev/null
}

echo "[repro] build A ..."
build_once "$A" "$ROOT/output/.repro/rootfs-a"
echo "[repro] build B ..."
build_once "$B" "$ROOT/output/.repro/rootfs-b"

name="kolinos-$(sed -n 's/^KOLIN_VERSION="\(.*\)"/\1/p' "$ROOT/VERSION")-corvo-arm64.tar.xz"
sum_a="$(sha256sum "$A/$name" | awk '{print $1}')"
sum_b="$(sha256sum "$B/$name" | awk '{print $1}')"

echo "[repro] A: $sum_a"
echo "[repro] B: $sum_b"
if [ "$sum_a" = "$sum_b" ]; then
    echo "[repro] ✔ builds idênticos (reprodutível)"
else
    echo "[repro] ✗ builds diferentes — veja o diff abaixo" >&2
    diff <(tar -tvJf "$A/$name") <(tar -tvJf "$B/$name") | head -40 || true
    exit 1
fi
