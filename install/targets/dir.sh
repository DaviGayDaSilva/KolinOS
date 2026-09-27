#!/usr/bin/env bash
# KolinOS install target: dir
#
# Deploys the rootfs into a directory on a Linux host (with root) and finishes
# the installation there. This is the path used to prepare images, to test the
# installer end-to-end, and as the staging step for an SD-card / disk-image
# install later (Phase 10). It does NOT partition disks or touch a bootloader.
#
# What it does:
#   1. extracts the rootfs into the target directory (preserving ownership),
#   2. runs the one-time first-boot setup inside the target (chroot),
#   3. prints how to enter the result.
#
# Because it writes a real root, it requires root and refuses obvious mistakes
# (target not empty, target is / or a system directory).
#
# Usage:
#   sudo bash install/targets/dir.sh --dest /path/to/root [ARCHIVE.tar.xz] [options]
#
# Options:
#   --dest DIR        Target directory (required, must be empty)
#   --no-verify       Skip the SHA-256 check
#   --sha256 HASH     Expected SHA-256 of the archive
#   --no-firstboot    Do not run the first-boot setup
#   --yes             Assume yes for prompts
#   -h, --help        Show this help
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_SELF_DIR/../lib/common.sh"

DEST=""
VERIFY=1
EXPECT_SHA=""
FIRSTBOOT=1
ARCHIVE=""

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dest)        DEST="$2"; shift 2 ;;
        --no-verify)   VERIFY=0; shift ;;
        --sha256)      EXPECT_SHA="$2"; shift 2 ;;
        --no-firstboot) FIRSTBOOT=0; shift ;;
        --yes)         KOLIN_ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*) die "opção desconhecida: $1" ;;
        *)  ARCHIVE="$1"; shift ;;
    esac
done

require_root
[ -n "$DEST" ] || die "--dest é obrigatório (diretório de destino)"

if [ -z "$ARCHIVE" ]; then
    ARCHIVE="$(kolin_find_archive || true)"
fi
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || die "rootfs não encontrado. Passe o caminho: $0 --dest DIR kolinos-*.tar.xz"

# Absolute destination path, then the safety guards.
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
kolin_guard_empty_dir "$DEST"

say "destino: $DEST"
kolin_verify_archive "$ARCHIVE" "$EXPECT_SHA" "$VERIFY"
kolin_confirm "extrair o KolinOS em $DEST?" || die "cancelado pelo usuário"

kolin_extract_rootfs "$ARCHIVE" "$DEST"

# ---------------------------------------------------------------------------
# First boot inside the target.
# ---------------------------------------------------------------------------
# Cross-arch needs qemu when the host is not the target architecture. We reuse
# the static qemu binary if the host provides one; otherwise first boot is
# deferred to the real machine.
kolin_dir_firstboot() {
    local dest="$1" qemu_backup="" rc=0

    [ -x "$dest/usr/bin/kolinos-firstboot" ] || { warn "kolinos-firstboot ausente; pulando"; return 0; }

    local host target cross=0
    host="$(uname -m)"
    target="$(chroot "$dest" /bin/sh -c 'dpkg --print-architecture' 2>/dev/null || echo unknown)"
    case "$host:$target" in
        x86_64:arm64|aarch64:arm64|arm64:arm64) : ;;
        x86_64:amd64|aarch64:amd64|amd64:amd64) : ;;
        *) cross=1 ;;
    esac

    if [ "$cross" = 1 ]; then
        if have qemu-aarch64-static && [ "$target" = arm64 ]; then
            mkdir -p "$dest/usr/bin"
            qemu_backup="$(mktemp)"
            if [ -e "$dest/usr/bin/qemu-aarch64-static" ]; then
                cp -a "$dest/usr/bin/qemu-aarch64-static" "$qemu_backup"
            fi
            cp "$(command -v qemu-aarch64-static)" "$dest/usr/bin/qemu-aarch64-static"
            warn "arquitetura estrangeira: first boot via qemu-aarch64-static (pode ser lento)"
        else
            warn "não é possível executar binários $target neste host ($host) sem qemu."
            warn "o first boot rodará automaticamente no primeiro login da máquina real."
            return 0
        fi
    fi

    # Minimal /proc and /dev so dpkg-query, locale-gen and systemctl probes work.
    mkdir -p "$dest/proc" "$dest/dev" "$dest/sys"
    mount -t proc proc "$dest/proc" 2>/dev/null || true
    mount --bind /dev "$dest/dev" 2>/dev/null || true
    mount --bind /sys "$dest/sys" 2>/dev/null || true
    if chroot "$dest" /usr/bin/kolinos-firstboot; then
        ok "first boot concluído"
    else
        rc=$?
        warn "first boot retornou $rc; o sistema tentará de novo no primeiro login"
    fi
    umount "$dest/sys" 2>/dev/null || true
    umount "$dest/dev" 2>/dev/null || true
    umount "$dest/proc" 2>/dev/null || true

    if [ -n "$qemu_backup" ]; then
        if [ -s "$qemu_backup" ]; then cp -a "$qemu_backup" "$dest/usr/bin/qemu-aarch64-static"
        else rm -f "$dest/usr/bin/qemu-aarch64-static"; fi
        rm -f "$qemu_backup"
    fi
    return 0
}

if [ "$FIRSTBOOT" = 1 ]; then
    say "executando o first boot ..."
    kolin_dir_firstboot "$DEST"
else
    warn "first boot desativado (--no-firstboot); rode /usr/bin/kolinos-firstboot depois"
fi

ok "KolinOS implantado em $DEST"
echo
echo "Para entrar (host com root):"
echo "    sudo chroot $DEST /bin/bash -l"
echo
echo "Este destino ainda não tem kernel nem bootloader: não inicializa sozinho."
echo "Uma imagem bootável é entregável da Fase 10 (veja docs/LIMITATIONS.md)."
