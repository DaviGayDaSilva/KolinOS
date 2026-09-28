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
# Reproducibility (FASE 4).
#
# kolin_effective_mirror resolves the Debian mirror to use for this build: the
# fixed snapshot when KOLIN_SNAPSHOT is set, otherwise the plain mirror. It is
# rendered into apt sources and passed to debootstrap.
# ---------------------------------------------------------------------------
kolin_effective_mirror() { # <base-mirror> -> snapshot URL or base mirror
    local base="$1"
    if [ -n "${KOLIN_SNAPSHOT:-}" ]; then
        case "$base" in
            *debian-security*) printf '%s/archive/debian-security/%s' "$KOLIN_SNAPSHOT_HOST" "$KOLIN_SNAPSHOT" ;;
            *)                 printf '%s/archive/debian/%s'          "$KOLIN_SNAPSHOT_HOST" "$KOLIN_SNAPSHOT" ;;
        esac
    else
        printf '%s' "$base"
    fi
}

# kolin_build_epoch prints a stable Unix timestamp for this build. It is the
# author date of HEAD, not the current clock, so a rebuild of the same commit
# produces byte-identical archives even hours apart. NOTE: it stays stable until
# you commit again — a dirty tree does not change it. Override with
# KOLIN_BUILD_EPOCH for a fully frozen, checked-in value.
kolin_build_epoch() {
    local e="${KOLIN_BUILD_EPOCH:-}"
    if [ -z "$e" ]; then
        e="$(git -C "$KOLIN_ROOT_DIR" log -1 --format=%ct 2>/dev/null || true)"
    fi
    [ -n "$e" ] || e="$(date -u +%s)"
    printf '%s' "$e"
}

kolin_iso_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

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
        # Drop an inline comment (needs whitespace before '#') and trim spaces.
        val="${val%%[[:space:]]#*}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val%\"}"; val="${val#\"}"
        sed -i "s|@${key}@|${val}|g" "$out"
    done < <(grep -E '^KOLIN[A-Z_]*=' "$KOLIN_ROOT_DIR/VERSION")
    # Values computed at build time (e.g. the snapshot mirror) are exported as
    # KOLIN_* in the environment rather than living in VERSION.
    while IFS='=' read -r key val; do
        [ -n "$key" ] || continue
        sed -i "s|@${key}@|${val}|g" "$out"
    done < <(env | grep -E '^KOLIN[A-Z_]*=')
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

# ---------------------------------------------------------------------------
# Reproducibility: stamp every file in the tree with one fixed timestamp so tar
# entries, dpkg's installed-mtime and the build metadata all agree, instead of
# carrying the wall clock. Requires root (chown/mknod on /dev nodes).
# ---------------------------------------------------------------------------
kolin_stamp_tree() {
    local r="$1" epoch="$2"
    find "$r" -xdev -exec touch -h -d "@$epoch" {} + 2>/dev/null || \
        warn "normalização de mtime falhou em alguns caminhos"
}

# ---------------------------------------------------------------------------
# Ownership normalisation (runs right before tar).
#
# The build runs as root, but files created by shell redirection (cat >, cp,
# install -d) inherit the *host's* uid/gid, which has no account inside the
# target — so /etc/kolinos, /root/.bashrc and friends would ship as uid 10001.
# The opposite mistake is just as bad: tar --owner=0 erases ids that ARE real
# accounts, leaving /home/<user> owned by root (mode 0700, so the user cannot
# read their own home) and apt's sandbox dirs without _apt.
#
# So: map every id with no matching account in the rootfs to root:root, and
# leave the rest untouched. Deterministic, so reproducible builds still hold.
# ---------------------------------------------------------------------------
kolin_normalize_owners() {
    local r="$1"
    local uid gid changed=0
    local -A valid_u=() valid_g=()

    while IFS=: read -r _ _ u _; do [ -n "$u" ] && valid_u["$u"]=1; done < "$r/etc/passwd"
    while IFS=: read -r _ _ g _; do [ -n "$g" ] && valid_g["$g"]=1; done < "$r/etc/group"

    for uid in $(find "$r" -xdev -printf '%U\n' 2>/dev/null | sort -u); do
        [ -n "${valid_u[$uid]:-}" ] && continue
        find "$r" -xdev -uid "$uid" -exec chown -h 0 {} + 2>/dev/null || true
        changed=1
    done
    for gid in $(find "$r" -xdev -printf '%G\n' 2>/dev/null | sort -u); do
        [ -n "${valid_g[$gid]:-}" ] && continue
        find "$r" -xdev -gid "$gid" -exec chgrp -h 0 {} + 2>/dev/null || true
        changed=1
    done
    [ "$changed" = 1 ] && log "donos normalizados (ids do host → root:root)"
    return 0
}

# ---------------------------------------------------------------------------
# /dev hygiene.
#
# A rootfs built in a container cannot create device nodes (no CAP_MKNOD), and
# debootstrap reports it as "Could not create /dev/ptmx". Worse, a chroot that
# did not get /dev bind-mounted lets /dev/null degrade into a regular file that
# silently swallows output — which then ships inside the archive. Never ship a
# regular file where a device belongs: drop those paths, then recreate the nodes
# when the kernel allows it (a real-root build); otherwise devtmpfs or proot
# provide them at runtime.
# ---------------------------------------------------------------------------
kolin_fix_dev() {
    local r="$1" d
    [ -d "$r/dev" ] || mkdir -p "$r/dev"

    for d in null zero full random urandom tty console; do
        if [ -e "$r/dev/$d" ] && [ ! -c "$r/dev/$d" ]; then
            warn "/dev/$d é arquivo comum (não device node) — removendo"
            rm -f "$r/dev/$d"
        fi
    done

    if [ -z "${_KOLIN_MKNOD_OK:-}" ]; then
        if mknod "$r/dev/.kolinos-mknod-test" c 1 3 2>/dev/null; then
            rm -f "$r/dev/.kolinos-mknod-test"; _KOLIN_MKNOD_OK=1
        else
            _KOLIN_MKNOD_OK=0
        fi
    fi

    mkdir -p "$r/dev/pts" "$r/dev/shm"
    if [ "$_KOLIN_MKNOD_OK" = 1 ]; then
        mknod -m 666 "$r/dev/null"    c 1 3 || true
        mknod -m 666 "$r/dev/zero"    c 1 5 || true
        mknod -m 666 "$r/dev/full"    c 1 7 || true
        mknod -m 666 "$r/dev/random"  c 1 8 || true
        mknod -m 666 "$r/dev/urandom" c 1 9 || true
        mknod -m 666 "$r/dev/tty"     c 5 0 || true
        mknod -m 600 "$r/dev/console" c 5 1 || true
    else
        log "/dev: mknod indisponível (container sem CAP_MKNOD); devtmpfs/proot criam os nós no boot"
    fi
    chmod 1777 "$r/dev/shm" 2>/dev/null || true
}

# Drop documentation / man pages (except copyright) at unpack time so every
# package installed afterwards stays small. Must run BEFORE debootstrap's
# second stage. Skipped when KOLIN_SLIM=0 (build.sh --full).
kolin_apply_slim() {
    local r="$1"
    [ "${KOLIN_SLIM:-1}" = 1 ] || { log "modo --full: mantendo docs/man/locales"; return 0; }
    mkdir -p "$r/etc/dpkg/dpkg.cfg.d"
    install -m 0644 "$KOLIN_ROOT_DIR/config/dpkg/99kolinos-slim.conf" \
        "$r/etc/dpkg/dpkg.cfg.d/99kolinos-slim"
}

# debootstrap's first stage extracts packages with dpkg-deb directly, bypassing
# dpkg.cfg.d — so docs/man/locales from the base system survive the unpack-time
# filter. This sweep removes the leftovers (and any installed before the filter
# was in place), keeping copyright files. Idempotent; safe to re-run.
kolin_slim_sweep() {
    local r="$1"
    [ "${KOLIN_SLIM:-1}" = 1 ] || return 0
    local d e
    rm -rf "$r"/usr/share/man/* "$r"/usr/share/man/.[!.]* 2>/dev/null || true
    rm -rf "$r"/usr/share/info/* "$r"/usr/share/info/.[!.]* 2>/dev/null || true
    rm -rf "$r"/usr/share/lintian/* "$r"/usr/share/bug/* 2>/dev/null || true
    # Locales: keep only C and the alias map.
    find "$r/usr/share/locale" -mindepth 1 -maxdepth 1 \
        ! -name C ! -name locale.alias -exec rm -rf {} + 2>/dev/null || true
    # Documentation: keep directories that carry a copyright file.
    if [ -d "$r/usr/share/doc" ]; then
        for d in "$r"/usr/share/doc/*; do
            [ -e "$d" ] || continue
            e="$(basename "$d")"
            case "$e" in .*|copyright) continue ;; esac
            if [ -d "$d" ] && [ -e "$d/copyright" ]; then continue; fi
            rm -rf "$d" 2>/dev/null || true
        done
    fi
    # i18n source data: only needed to generate locales other than C.UTF-8.
    if [ "$KOLIN_LOCALE" = "C.UTF-8" ]; then
        rm -rf "$r"/usr/share/i18n/* 2>/dev/null || true
    fi
}

kolin_chroot() {
    local r="$1"; shift
    kolin_ensure_qemu "$r"
    local rc=0

    # Cross-arch normally relies on binfmt_misc: the kernel hands aarch64 ELFs to
    # qemu automatically. When it is unavailable (read-only /proc in some
    # containers — the same situation Termux users hit), proot takes over: it
    # intercepts execve and rewrites the interpreter, so nested execs (bash →
    # apt → dpkg) work too, which a bare qemu wrapper cannot do. proot's -R
    # binds /dev, /proc and /sys itself, so the pseudo-filesystems are not
    # mounted for this path.
    local cross=0
    [ "$(uname -m)" != "aarch64" ] && [ "${DEB_ARCH:-${KOLIN_ARCH:-}}" = "arm64" ] && cross=1
    if [ "$cross" = 1 ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        have proot || die "cross-arch sem binfmt_misc: instale 'proot' (apt install proot)"
        log "binfmt_misc indisponível — usando proot + qemu-aarch64-static"
        proot -R "$r" -q /usr/bin/qemu-aarch64-static -w / "$@" || rc=$?
        return $rc
    fi

    kolin_mount_pseudo "$r"
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
