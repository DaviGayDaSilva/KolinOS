#!/usr/bin/env bash
# shellcheck shell=bash
# KolinOS installer — shared helpers for the install front-end and targets.
#
# This library is intentionally standalone: it is copied into the ISO installer
# tree and on a target machine may run with nothing but bash, tar and the usual
# coreutils. It must NOT source the build library (build/lib/common.sh).

set -euo pipefail

KOLIN_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOLIN_SOURCE_ROOT="$(cd "$KOLIN_INSTALL_DIR/.." && pwd)"

KOLIN_NAME="KolinOS"; KOLIN_VERSION="0"; KOLIN_CODENAME="Corvo"
KOLIN_ARCH="arm64"; KOLIN_APT_REPO_URL=""; KOLIN_DEFAULT_USER="kolin"
for _v in "$KOLIN_SOURCE_ROOT/VERSION" "$KOLIN_SOURCE_ROOT/../VERSION"; do
    if [ -f "$_v" ]; then
        # shellcheck disable=SC1090
        . "$_v"
        break
    fi
done
KOLIN_CODENAME_LOWER="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    _ic_reset=$'\033[0m'; _ic_purple=$'\033[1;35m'
    _ic_yellow=$'\033[1;33m'; _ic_red=$'\033[1;31m'; _ic_green=$'\033[1;32m'
else
    _ic_reset=''; _ic_purple=''; _ic_yellow=''; _ic_red=''; _ic_green=''
fi
say()  { printf '%s[KolinOS]%s %s\n' "$_ic_purple" "$_ic_reset" "$*"; }
ok()   { printf '%s[KolinOS]%s %s\n' "$_ic_green"  "$_ic_reset" "$*"; }
warn() { printf '%s[KolinOS]%s %s\n' "$_ic_yellow" "$_ic_reset" "$*" >&2; }
die()  { printf '%s[KolinOS][erro]%s %s\n' "$_ic_red" "$_ic_reset" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "este passo precisa de root. Rode: sudo $0 $*"
}

# Detect where we are running, so the front-end can pick a sensible default.
#   termux   — Termux on Android ($PREFIX set), no root: proot-distro.
#   android  — Android shell with root: still no kernel, proot-family only.
#   linux    — a normal Linux host with root available.
kolin_env() {
    case "${PREFIX:-}" in
        *com.termux*) printf 'termux'; return ;;
    esac
    case "$(uname -s)" in
        Linux) : ;;
        *)     printf 'unsupported'; return ;;
    esac
    if [ -n "${ANDROID_ROOT:-}" ] || [ -n "${ANDROID_DATA:-}" ]; then
        printf 'android'; return
    fi
    printf 'linux'
}

# Scratch space for a run. Each target gets its own directory so a failed
# attempt can be cleaned without touching the others.
kolin_mkrundir() {
    local base="${TMPDIR:-/tmp}" d
    d="$(mktemp -d "$base/kolinos-install.XXXXXX" 2>/dev/null || mktemp -d)"
    printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Rootfs archive discovery + integrity
# ---------------------------------------------------------------------------
# Prints the path of the best candidate archive, or nothing.
kolin_find_archive() {
    local hint="${1:-}" cand
    if [ -n "$hint" ] && [ -f "$hint" ]; then printf '%s' "$hint"; return 0; fi
    for cand in \
        "$KOLIN_INSTALL_DIR"/rootfs/kolinos-*.tar.xz \
        "$KOLIN_SOURCE_ROOT"/output/kolinos-*.tar.xz \
        "$KOLIN_SOURCE_ROOT"/rootfs/kolinos-*.tar.xz \
        "$PWD"/kolinos-*.tar.xz; do
        [ -f "$cand" ] && printf '%s' "$cand" && return 0
    done
    return 1
}

# Expected SHA-256 for an archive: an explicit value wins, then a SHA256SUMS
# next to it, then the ISO MANIFEST.
kolin_expected_sha() {
    local archive="$1" explicit="${2:-}" base dir exp
    if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
    base="$(basename "$archive")"; dir="$(dirname "$archive")"
    for cand in "$dir/SHA256SUMS" "$KOLIN_SOURCE_ROOT/SHA256SUMS" \
                "$KOLIN_SOURCE_ROOT/output/SHA256SUMS" "$KOLIN_SOURCE_ROOT/../MANIFEST"; do
        [ -f "$cand" ] || continue
        case "$cand" in
            *MANIFEST) exp="$(awk -F= '$1=="ROOTFS_SHA256"{print $2}' "$cand")" ;;
            *) exp="$(awk -v f="$base" '$2==f || $2=="./"f || $2=="*"f {print $1}' "$cand" | head -1)" ;;
        esac
        [ -n "$exp" ] && printf '%s' "$exp" && return 0
    done
    return 1
}

kolin_verify_archive() {
    local archive="$1" explicit="${2:-}" verify="${3:-1}"
    [ "$verify" = 1 ] || { warn "verificação de checksum desativada"; return 0; }
    local exp got
    if ! exp="$(kolin_expected_sha "$archive" "$explicit")"; then
        warn "nenhum checksum encontrado para $(basename "$archive") — pulando"
        return 0
    fi
    have sha256sum || die "sha256sum não encontrado; instale coreutils ou use --no-verify"
    got="$(sha256sum "$archive" | awk '{print $1}')"
    [ "$got" = "$exp" ] || die "checksum não confere para $(basename "$archive")! esperado $exp, obtido $got"
    ok "checksum OK ($(basename "$archive"))"
}

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------
kolin_confirm() {
    local prompt="$1" answer
    if [ "${KOLIN_ASSUME_YES:-0}" = 1 ]; then return 0; fi
    [ -t 0 ] || die "confirmação necessária mas a entrada não é interativa (use --yes)"
    printf '%s [s/N] ' "$prompt" >&2
    read -r answer || answer=""
    case "$answer" in s|S|y|Y|sim|SIM|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Refuse to operate on a path that is clearly a live system, and make sure a
# directory target is empty before writing into it.
kolin_guard_empty_dir() {
    local dir="$1"
    [ -n "$dir" ] || die "diretório de destino vazio"
    case "$dir" in /|/usr|/etc|/var|/home|/root|/boot) die "destino perigoso: $dir" ;; esac
    [ -e "$dir" ] && [ ! -d "$dir" ] && die "destino existe e não é diretório: $dir"
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        die "diretório de destino não está vazio: $dir (use um caminho novo ou esvazie-o)"
    fi
}

# Extract the rootfs archive into a directory. Preserves ownership/permissions
# (needs root) and does not follow paths out of the target.
kolin_extract_rootfs() {
    local archive="$1" dest="$2"
    mkdir -p "$dest"
    say "extraindo $(basename "$archive") em $dest ..."
    if [ "$(id -u)" -eq 0 ]; then
        tar -xJp --numeric-owner -C "$dest" -f "$archive"
    else
        warn "sem root: extraindo sem preservar dono/grupo (não use para um root de verdade)"
        tar -xJp -C "$dest" -f "$archive"
    fi
}
