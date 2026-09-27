#!/usr/bin/env bash
# KolinOS install target: disk (GROUNDWORK — Phase 10)
#
# Writes the rootfs onto an already-prepared block device (SD card, USB stick,
# or a partition). This is intentionally conservative: it does NOT create a
# partition table and never guesses. Partitioning, and especially a *bootable*
# result, belong to Phase 10, which needs a real kernel and a bootloader.
#
# Even after this runs, the medium is NOT bootable: it has no kernel, no
# bootloader and no Android/ARM boot chain. It becomes bootable only once Phase
# 10 adds those. See docs/LIMITATIONS.md.
#
# Because this destroys data on a block device, it requires BOTH --force and
# --yes, and refuses devices that hold the running system.
#
# Usage:
#   sudo bash install/targets/disk.sh --device /dev/sdX1 [ARCHIVE.tar.xz] [options]
#
# Options:
#   --device PATH     Block device or partition (required)
#   --format FS       Format the device first (ext4|none; default: none)
#   --mountpoint DIR  Where to mount while writing (default: temp dir)
#   --no-verify       Skip the SHA-256 check
#   --sha256 HASH     Expected SHA-256 of the archive
#   --no-firstboot    Do not run the first-boot setup
#   --force           Acknowledge that the device will be overwritten
#   --yes             Assume yes for prompts
#   -h, --help        Show this help
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_SELF_DIR/../lib/common.sh"

DEVICE=""
FORMAT="none"
MNT=""
VERIFY=1
EXPECT_SHA=""
FIRSTBOOT=1
FORCE=0
ARCHIVE=""

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device)      DEVICE="$2"; shift 2 ;;
        --format)      FORMAT="$2"; shift 2 ;;
        --mountpoint)  MNT="$2"; shift 2 ;;
        --no-verify)   VERIFY=0; shift ;;
        --sha256)      EXPECT_SHA="$2"; shift 2 ;;
        --no-firstboot) FIRSTBOOT=0; shift ;;
        --force)       FORCE=1; shift ;;
        --yes)         KOLIN_ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*) die "opção desconhecida: $1" ;;
        *)  ARCHIVE="$1"; shift ;;
    esac
done

require_root
[ -n "$DEVICE" ] || die "--device é obrigatório (ex.: /dev/sdb1)"
[ -b "$DEVICE" ] || die "não é um dispositivo de bloco: $DEVICE"
[ "$FORCE" = 1 ] || die "operação destrutiva: repita com --force (e leia o --help)"
case "$FORMAT" in ext4|none) : ;; *) die "--format aceita apenas 'ext4' ou 'none'" ;; esac

warn "ATENÇÃO: $DEVICE será apagado por completo."
warn "Este medium NÃO será inicializável (sem kernel/bootloader — Fase 10)."
kolin_confirm "confirmar a escrita em $DEVICE?" || die "cancelado pelo usuário"

# Refuse a device that backs the running root, /boot, or anything mounted.
if mountpoint -q / && have findmnt; then
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    [ "$root_src" = "$DEVICE" ] && die "$DEVICE contém o sistema em execução"
fi
if have lsblk && lsblk -no MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q .; then
    die "$DEVICE está montado; desmonte antes"
fi

if [ -z "$ARCHIVE" ]; then
    ARCHIVE="$(kolin_find_archive || true)"
fi
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || die "rootfs não encontrado. Passe o caminho: $0 --device DEV kolinos-*.tar.xz"
kolin_verify_archive "$ARCHIVE" "$EXPECT_SHA" "$VERIFY"

if [ "$FORMAT" = ext4 ]; then
    have mkfs.ext4 || die "mkfs.ext4 não encontrado (instale e2fsprogs)"
    say "formatando $DEVICE como ext4 ..."
    mkfs.ext4 -F -L KOLINOS "$DEVICE"
fi

OWN_MNT=0
if [ -z "$MNT" ]; then
    MNT="$(kolin_mkrundir)/mnt"; mkdir -p "$MNT"; OWN_MNT=1
else
    mkdir -p "$MNT"
fi

say "montando $DEVICE em $MNT ..."
mount "$DEVICE" "$MNT"
cleanup() { umount "$MNT" 2>/dev/null || true; [ "$OWN_MNT" = 1 ] && rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

# The target directory here is the mount point: it must be empty to proceed.
if [ -n "$(ls -A "$MNT" 2>/dev/null)" ]; then
    die "o dispositivo já contém arquivos ($MNT não está vazio); formate-o com --format ext4"
fi
kolin_extract_rootfs "$ARCHIVE" "$MNT"

if [ "$FIRSTBOOT" = 1 ]; then
    say "executando o first boot ..."
    if [ -x "$MNT/usr/bin/kolinos-firstboot" ]; then
        chroot "$MNT" /usr/bin/kolinos-firstboot \
            || warn "first boot retornou erro; rode /usr/bin/kolinos-firstboot na máquina real"
    else
        warn "kolinos-firstboot ausente; pulando"
    fi
fi

sync
ok "KolinOS escrito em $DEVICE"
echo
echo "Este medium NÃO inicializa sozinho: falta kernel e bootloader."
echo "Para tornar o KolinOS bootável é necessário o trabalho da Fase 10"
echo "(kernel próprio + bootloader; em Android, bootloader desbloqueado)."
echo "Veja docs/LIMITATIONS.md."
