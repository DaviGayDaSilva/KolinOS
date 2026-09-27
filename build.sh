#!/usr/bin/env bash
# KolinOS build system — orchestrator.
#
# Runs the stages in build/stages/ in order to produce a personalized Debian
# ARM64 root filesystem. Each stage is an independent script sourced with the
# environment below; it must define a function named stage_main().
#
# Usage:
#   sudo bash build.sh [options]
#
# Options:
#   --arch ARCH        Target Debian architecture (default: arm64)
#   --suite SUITE      Debian suite (default: trixie)
#   --mirror URL       Debian mirror (default: http://deb.debian.org/debian)
#   --snapshot STAMP   Pin packages to snapshot.debian.org at STAMP
#                      (YYYYMMDDTHHMMSSZ) for a reproducible build
#   --reproducible     Shortcut for --snapshot on the pinned date in VERSION
#   --epoch EPOCH      Fixed Unix timestamp for archives/manifests (reproducible)
#   --output DIR       Where to write artifacts (default: ./output)
#   --rootfs DIR       Rootfs working dir (default: ./rootfs)
#   --only NAMES       Comma-separated list of stage numbers to run (e.g. 30,40)
#   --force            Recreate an existing rootfs from scratch
#   --keep-qemu        Keep the qemu-user-static binary inside the rootfs
#   --slim / --full    Slim mode (default): drop docs, man pages and non-C
#                      locales at unpack time. --full keeps them all.
#   --include-source   Copy the KolinOS source tree into the rootfs docs
#   -h, --help         Show this help

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/build/lib/common.sh"

KOLIN_FORCE=0
KOLIN_KEEP_QEMU=0
KOLIN_INCLUDE_SOURCE=0
KOLIN_NO_ISO=0
KOLIN_SLIM=1
KOLIN_ONLY_STAGES=""
KOLIN_OUTPUT_DIR="$KOLIN_ROOT_DIR/output"
KOLIN_ROOTFS="$KOLIN_ROOT_DIR/rootfs"
# Reproducibility overrides (empty = use VERSION).
KOLIN_SNAPSHOT="${KOLIN_SNAPSHOT:-}"
KOLIN_BUILD_EPOCH="${KOLIN_BUILD_EPOCH:-}"
# Where snapshot.debian.org lives; kept in one place so a mirror can replace it.
KOLIN_SNAPSHOT_HOST="http://snapshot.debian.org"

DEB_ARCH=""

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)           KOLIN_ARCH="$2"; shift 2 ;;
        --suite)          KOLIN_DEBIAN_SUITE="$2"; shift 2 ;;
        --mirror)         KOLIN_DEBIAN_MIRROR="$2"; shift 2 ;;
        --snapshot)       KOLIN_SNAPSHOT="$2"; shift 2 ;;
        --reproducible)   KOLIN_SNAPSHOT="${KOLIN_SNAPSHOT:-20250901T000000Z}"; shift ;;
        --epoch)          KOLIN_BUILD_EPOCH="$2"; shift 2 ;;
        --output)         KOLIN_OUTPUT_DIR="$2"; shift 2 ;;
        --rootfs)         KOLIN_ROOTFS="$2"; shift 2 ;;
        --only)           KOLIN_ONLY_STAGES="$2"; shift 2 ;;
        --force)          KOLIN_FORCE=1; shift ;;
        --keep-qemu)      KOLIN_KEEP_QEMU=1; shift ;;
        --slim)           KOLIN_SLIM=1; shift ;;
        --full)           KOLIN_SLIM=0; shift ;;
        --include-source) KOLIN_INCLUDE_SOURCE=1; shift ;;
        --no-iso)         KOLIN_NO_ISO=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "opção desconhecida: $1 (use --help)" ;;
    esac
done

# Map KolinOS arch names to debootstrap arch names.
case "$KOLIN_ARCH" in
    arm64|aarch64) DEB_ARCH="arm64" ;;
    amd64|x86_64)  DEB_ARCH="amd64" ;;
    armhf|arm)     DEB_ARCH="armhf" ;;
    i386)          DEB_ARCH="i386"  ;;
    riscv64)       DEB_ARCH="riscv64" ;;
    *) die "arquitetura não suportada: $KOLIN_ARCH" ;;
esac

export KOLIN_ARCH DEB_ARCH
export KOLIN_FORCE KOLIN_KEEP_QEMU KOLIN_INCLUDE_SOURCE KOLIN_NO_ISO KOLIN_SLIM
export KOLIN_ROOTFS KOLIN_OUTPUT_DIR
export KOLIN_CODENAME_LOWER
export KOLIN_SNAPSHOT KOLIN_SNAPSHOT_HOST

# Resolve the fixed build timestamp once, before any artifact is written.
KOLIN_BUILD_EPOCH="$(kolin_build_epoch)"
export KOLIN_BUILD_EPOCH

require_root
mkdir -p "$KOLIN_OUTPUT_DIR" "$KOLIN_ROOTFS"

log "KolinOS ${KOLIN_VERSION} (${KOLIN_CODENAME}) — target ${DEB_ARCH}/${KOLIN_DEBIAN_SUITE}"
log "host: $(uname -m) $(uname -s) — rootfs: $KOLIN_ROOTFS"
log "build epoch: $KOLIN_BUILD_EPOCH ($(kolin_iso_utc "$KOLIN_BUILD_EPOCH"))"
if [ -n "$KOLIN_SNAPSHOT" ]; then
    log "snapshot Debian: $KOLIN_SNAPSHOT (build reprodutível)"
else
    log "mirror ao vivo (sem snapshot): o resultado pode variar entre builds"
fi

mapfile -t STAGES < <(find "$SELF_DIR/build/stages" -maxdepth 1 -name '[0-9][0-9]-*.sh' | sort)
[ "${#STAGES[@]}" -gt 0 ] || die "nenhum estágio encontrado em build/stages/"

start_ts=$SECONDS
for stage in "${STAGES[@]}"; do
    name="$(basename "$stage")"
    num="${name%%-*}"
    if [ -n "$KOLIN_ONLY_STAGES" ]; then
        case ",$KOLIN_ONLY_STAGES," in
            *",$num,"*) : ;;
            *) log "pulando $name (--only)"; continue ;;
        esac
    fi
    step "$name"
    # shellcheck disable=SC1090
    source "$stage"
    declare -f stage_main >/dev/null || die "stage $name não define stage_main()"
    stage_main
    unset -f stage_main
done

log "build concluído em $((SECONDS - start_ts))s"

# ---------------------------------------------------------------------------
# Phase 8 (partial): assemble a distributable ISO that carries the rootfs and
# the Termux installer. NOTE: this is NOT a bootable OS image — no kernel or
# bootloader is included. Booting on real hardware requires Phase 10.
# ---------------------------------------------------------------------------
if [ "$KOLIN_NO_ISO" != 1 ]; then
    if bash "$SELF_DIR/scripts/artifacts/make-iso.sh" "$KOLIN_OUTPUT_DIR"; then
        log "ISO gerada"
    else
        warn "geração da ISO falhou (o rootfs continua válido)"
    fi
fi

log "artefatos em: $KOLIN_OUTPUT_DIR"
ls -lh "$KOLIN_OUTPUT_DIR" 2>/dev/null || true
