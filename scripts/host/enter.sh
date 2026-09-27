#!/usr/bin/env bash
# enter.sh — open an interactive shell inside a built KolinOS rootfs.
#
# Two modes:
#   * On a Linux host with root: real chroot (+QEMU for cross-arch).
#   * Inside Termux: it tells you to use proot-distro instead (see
#     scripts/termux/install.sh); proot needs no root.
#
# Usage: sudo bash scripts/host/enter.sh [rootfs-dir] [-- command...]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../build/lib/common.sh
source "$ROOT/build/lib/common.sh"

R="${1:-$ROOT/rootfs}"; shift || true
[ -d "$R" ] || die "rootfs não encontrado: $R"

# Detect Termux: proot is required there and chroot will not work.
case "${PREFIX:-}" in
    *com.termux*)
        log "Detectado Termux. Use proot-distro em vez de chroot:"
        echo "    bash $ROOT/scripts/termux/install.sh <rootfs.tar.xz>"
        echo "    kolinos"
        exit 0
        ;;
esac

require_root
kolin_ensure_qemu "$R"
kolin_mount_pseudo "$R"
cleanup() { kolin_umount_pseudo "$R"; }
trap cleanup EXIT

if [ "$#" -eq 0 ]; then
    log "entrando em $R (saia com 'exit')"
    chroot "$R" /bin/bash -l
else
    chroot "$R" "$@"
fi
