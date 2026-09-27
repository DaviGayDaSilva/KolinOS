#!/usr/bin/env bash
# kolinos-install — install KolinOS with one command.
#
# This is the friendly front-end. It looks at where it is running and picks the
# right backend from install/targets/:
#
#   Termux / Android (no root) -> targets/proot.sh   (proot-distro container)
#   Linux with root            -> targets/dir.sh     (deploy into a directory)
#                              or targets/disk.sh    (write to an SD card)
#
# It never pretends to do what the platform cannot: there is no kernel and no
# bootloader here, so none of these produce a bootable phone. See
# docs/LIMITATIONS.md and docs/PHASE6.md.
#
# Usage:
#   bash install/kolinos-install.sh [ARCHIVE.tar.xz] [options]
#
# Options:
#   --target proot|dir|disk   Force a backend (default: auto)
#   --dest DIR                For --target dir
#   --device DEV              For --target disk
#   --format ext4|none        For --target disk
#   --name NAME               Container name for proot (default: kolinos)
#   --no-verify               Skip the SHA-256 check
#   --sha256 HASH             Expected SHA-256 of the archive
#   --no-firstboot            Do not run the first-boot setup
#   --yes                     Assume yes for prompts
#   -h, --help                Show this help
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_SELF_DIR/lib/common.sh"

TARGET="auto"
ARCHIVE=""
FORWARD=()

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --target)   TARGET="$2"; shift 2 ;;
        --dest|--device|--format|--name|--sha256) FORWARD+=("$1" "$2"); shift 2 ;;
        --no-verify|--no-firstboot|--yes) FORWARD+=("$1"); shift ;;
        -h|--help)  usage; exit 0 ;;
        -*) die "opção desconhecida: $1" ;;
        *)  ARCHIVE="$1"; shift ;;
    esac
done

case "$TARGET" in auto|proot|dir|disk) : ;; *) die "--target aceita proot, dir ou disk"; esac

ENV_KIND="$(kolin_env)"
[ -n "$ARCHIVE" ] || ARCHIVE="$(kolin_find_archive || true)"
if [ -n "$ARCHIVE" ]; then
    ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
fi

# ---------------------------------------------------------------------------
# Choose the backend
# ---------------------------------------------------------------------------
if [ "$TARGET" = auto ]; then
    case "$ENV_KIND" in
        termux|android) TARGET="proot" ;;
        linux)
            # On Linux, 'dir' is the safe default (no disk is touched).
            TARGET="dir"
            ;;
        *) die "sistema não suportado: $(uname -s). Veja docs/LIMITATIONS.md" ;;
    esac
fi

case "$ENV_KIND:$TARGET" in
    termux:dir|termux:disk)
        die "no Termux não há root nem acesso a dispositivo de bloco; use --target proot" ;;
    android:dir|android:disk)
        die "Android sem kernel próprio não suporta escrever um rootfs de verdade; use --target proot" ;;
esac

if [ "$TARGET" = proot ]; then
    : # proot needs no root
else
    [ "$(id -u)" -eq 0 ] || die "o target '$TARGET' precisa de root. Rode com sudo."
fi

say "ambiente: $ENV_KIND   target: $TARGET"
[ -n "$ARCHIVE" ] || warn "nenhum rootfs encontrado; o backend tentará localizá-lo"
BACKEND="$_SELF_DIR/targets/$TARGET.sh"
[ -f "$BACKEND" ] || die "backend não encontrado: $BACKEND"

# ---------------------------------------------------------------------------
# Hand over to the backend
# ---------------------------------------------------------------------------
set -- "$BACKEND"
if [ -n "$ARCHIVE" ]; then set -- "$@" "$ARCHIVE"; fi
if [ "${#FORWARD[@]}" -gt 0 ]; then set -- "$@" "${FORWARD[@]}"; fi
exec bash "$@"
