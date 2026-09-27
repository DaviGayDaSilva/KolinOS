#!/data/data/com.termux/files/usr/bin/bash
# KolinOS installer for Termux (Android, arm64, NO ROOT REQUIRED).
#
# This is now a thin shim kept for backwards compatibility. The unified
# installer lives in install/kolinos-install.sh and picks the right backend
# automatically (proot on Termux, dir/disk on a root Linux host). See
# docs/PHASE6.md.
#
# Usage:
#   bash install.sh [ROOTFS.tar.xz] [options]
#
# All options are forwarded to install/kolinos-install.sh --target proot.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"

for cand in \
    "$SELF_DIR/../../install/kolinos-install.sh" \
    "$SELF_DIR/../install/kolinos-install.sh" \
    "$ROOT/install/kolinos-install.sh"; do
    if [ -f "$cand" ]; then
        exec bash "$cand" --target proot "$@"
    fi
done

printf '\033[1;31m[KolinOS][erro]\033[0m não encontrei install/kolinos-install.sh perto de %s\n' "$SELF_DIR" >&2
printf 'Use o instalador unificado: install/kolinos-install.sh --target proot <rootfs.tar.xz>\n' >&2
exit 1
