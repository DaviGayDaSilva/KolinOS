#!/usr/bin/env bash
# shellcheck shell=bash
# KolinOS — shared build helpers.
# Sourced by build.sh and by every stage in build/stages/.

set -euo pipefail

# Project root is two levels up from build/lib/.
KOLIN_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../VERSION
source "$KOLIN_ROOT_DIR/VERSION"

KOLIN_CODENAME_LOWER="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    _c_reset=$'\033[0m'; _c_purple=$'\033[1;35m'; _c_yellow=$'\033[1;33m'; _c_red=$'\033[1;31m'
else
    _c_reset=''; _c_purple=''; _c_yellow=''; _c_red=''
fi
log()  { printf '%s[kolinos]%s %s\n' "$_c_purple" "$_c_reset" "$*"; }
step() { printf '%s[kolinos]%s ==> %s\n' "$_c_purple" "$_c_reset" "$*"; }
warn() { printf '%s[aviso]%s %s\n'   "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%s[erro]%s %s\n'    "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "Este passo precisa de root. Rode: sudo bash build.sh"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Templating: replace @KOLIN_*@ placeholders with values from VERSION.
# ---------------------------------------------------------------------------
render_template() {
    local in="$1" out="$2" key val line
    [ -f "$in" ] || die "template não encontrado: $in"
    mkdir -p "$(dirname "$out")"
    cp "$in" "$out"
    while IFS= read -r line; do
        case "$line" in KOLIN*=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        # Strip an inline comment and surrounding quotes.
        val="${val%%[ 	]#*}"
        val="${val%\"}"; val="${val#\"}"
        sed -i "s|@${key}@|${val}|g" "$out"
    done < <(grep -E '^KOLIN[A-Z_]*=' "$KOLIN_ROOT_DIR/VERSION")
    sed -i "s|@KOLIN_CODENAME_LOWER@|${KOLIN_CODENAME_LOWER}|g" "$out"
}

# ---------------------------------------------------------------------------
# chroot into the target rootfs, transparently handling foreign-arch (QEMU)
# and the pseudo-filesystems apt/ldconfig expect.
# ---------------------------------------------------------------------------
_KOLIN_MOUNTS_UP=0

kolin_mount_pseudo() {
    local r="$1"
    mkdir -p "$r/dev" "$r/dev/pts" "$r/proc" "$r/sys"
    mount --bind /dev     "$r/dev"
    mount --bind /dev/pts "$r/dev/pts"
    mount -t proc proc    "$r/proc" 2>/dev/null || mount --bind /proc "$r/proc"
    mount --bind /sys     "$r/sys"
    _KOLIN_MOUNTS_UP=1
}

kolin_umount_pseudo() {
    local r="$1"
    [ "$_KOLIN_MOUNTS_UP" = 1 ] || return 0
    umount "$r/dev/pts" 2>/dev/null || true
    umount "$r/dev"     2>/dev/null || true
    umount "$r/proc"    2>/dev/null || true
    umount "$r/sys"     2>/dev/null || true
    _KOLIN_MOUNTS_UP=0
}

# Copy the static qemu binary into the rootfs when host and target differ.
kolin_ensure_qemu() {
    local r="$1"
    if [ "$(uname -m)" = "aarch64" ]; then
        return 0
    fi
    have qemu-aarch64-static || die "qemu-user-static não instalado no host (apt install qemu-user-static)"
    mkdir -p "$r/usr/bin"
    cmp -s "$(command -v qemu-aarch64-static)" "$r/usr/bin/qemu-aarch64-static" 2>/dev/null || \
        cp "$(command -v qemu-aarch64-static)" "$r/usr/bin/qemu-aarch64-static"
}

kolin_remove_qemu() {
    local r="$1"
    rm -f "$r/usr/bin/qemu-aarch64-static"
}

kolin_chroot() {
    local r="$1"; shift
    kolin_ensure_qemu "$r"
    kolin_mount_pseudo "$r"
    local rc=0
    # shellcheck disable=SC2068
    chroot "$r" "$@" || rc=$?
    kolin_umount_pseudo "$r"
    return $rc
}

# Run a shell snippet (string) inside the rootfs with a strict shell.
kolin_run() {
    local r="$1"; shift
    kolin_chroot "$r" /bin/bash -euc "$*"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

human_size() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
