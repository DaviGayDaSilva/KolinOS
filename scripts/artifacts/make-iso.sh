#!/usr/bin/env bash
# make-iso.sh — assemble the distributable KolinOS ISO.
#
# This ISO is a DATA/CARRIER image: it contains the personalized ARM64 rootfs
# archive plus this project's source and the Termux installer. It is NOT a
# bootable operating-system image — it has no kernel and no bootloader.
# A bootable install medium is a Phase-10 deliverable (needs a real kernel and
# bootloader support).
#
# Usage: make-iso.sh [OUTPUT_DIR]   (default: ./output)
set -euo pipefail

SHORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SHORT_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"
KOLIN_CODENAME_LOWER="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"
OUT="${1:-$ROOT/output}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-iso.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Reproducible builds: reuse the rootfs epoch (git commit date) for the ISO
# filesystem, volume dates and manifest, so the ISO is stable across rebuilds.
EPOCH="${KOLIN_BUILD_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date -u +%s)}"
ISO_DATE="$(date -u -d "@$EPOCH" +%Y%m%d%H%M%S00 2>/dev/null || date -u +%Y%m%d%H%M%S00)"
BUILD_DATE="$(date -u -d "@$EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '[iso] %s\n' "$*"; }
die() { printf '[iso][erro] %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
have xorriso || die "xorriso não instalado (Debian: apt install xorriso)"

mkdir -p "$OUT"
TARBALL="$(ls "$OUT"/kolinos-*-"$KOLIN_ARCH".tar.xz 2>/dev/null | head -1 || true)"
[ -n "$TARBALL" ] || die "archives do rootfs não encontrado em $OUT (rode o build antes)"

log "montando árvore em $STAGE"
mkdir -p "$STAGE/rootfs" "$STAGE/docs" "$STAGE/install" \
         "$STAGE/src/scripts/termux" "$STAGE/src/scripts/host" \
         "$STAGE/src/config" "$STAGE/src/packages" "$STAGE/src/tools"

# Rootfs + project source payload.
cp -a "$TARBALL" "$STAGE/rootfs/"
cp -a "$ROOT/VERSION" "$ROOT/LICENSE" "$ROOT/build.sh" "$STAGE/src/"
cp -a "$ROOT/build" "$ROOT/config" "$ROOT/packages" "$ROOT/tools" "$STAGE/src/"
cp -a "$ROOT/docs/." "$STAGE/docs/"
cp -a "$ROOT/scripts/termux" "$ROOT/scripts/host" "$STAGE/src/scripts/" 2>/dev/null || true
cp -a "$ROOT/repo" "$STAGE/src/" 2>/dev/null || true
# Unified installer (FASE 6): positional install/ tree, self-contained.
cp -a "$ROOT/install/." "$STAGE/install/"

# Manifest with the archive checksum, consumed by the Termux installer.
SUM="$(sha256sum "$TARBALL" | awk '{print $1}')"
cat > "$STAGE/MANIFEST" <<EOF
KOLIN_NAME=$KOLIN_NAME
KOLIN_VERSION=$KOLIN_VERSION
KOLIN_CODENAME=$KOLIN_CODENAME
KOLIN_ARCH=$KOLIN_ARCH
ROOTFS_FILE=rootfs/$(basename "$TARBALL")
ROOTFS_SHA256=$SUM
BUILD_DATE=$BUILD_DATE
EOF

cat > "$STAGE/README.txt" <<EOF
KolinOS ${KOLIN_VERSION} (${KOLIN_CODENAME}) — arm64
=====================================================

Este ISO é um CARRIER de dados, não uma imagem inicializável.
Ele contém:

  rootfs/    root filesystem Debian ARM64 personalizado como KolinOS
  install/   instalador unificado (kolinos-install.sh + backends proot/dir/disk)
  src/       código-fonte do sistema de build
  docs/      documentação (fases, limitações, roadmap)
  MANIFEST   metadados + checksum SHA-256 do rootfs

Como usar no Termux (Android, arm64):

  pkg install proot-distro
  bash install/kolinos-install.sh rootfs/$(basename "$TARBALL")

Em um host Linux com root (implantar em um diretório):

  sudo bash install/kolinos-install.sh --target dir --dest /opt/kolinos \
       rootfs/$(basename "$TARBALL")

Detalhes: veja docs/README.md, docs/PHASES.md e docs/PHASE6.md.
Base: Debian ${KOLIN_DEBIAN_SUITE}. Licenças dos pacotes: /usr/share/doc/*/copyright.
EOF

VOL="KOLINOS_$(printf '%s' "$KOLIN_VERSION" | tr -d '.')"
VOL="${VOL:0:16}"
ISO="$OUT/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.iso"

log "gerando $ISO"
xorriso -as mkisofs \
    -iso-level 3 \
    -rock -joliet -joliet-long \
    -volid "$VOL" \
    -publisher "KolinOS" \
    -preparer "KolinOS build system" \
    --set_all_file_dates "$ISO_DATE" \
    -o "$ISO" "$STAGE" >/dev/null

( cd "$OUT" && sha256sum "$(basename "$ISO")" >> SHA256SUMS )
log "ISO: $(du -h "$ISO" | awk '{print $1}')"
echo "$ISO"
