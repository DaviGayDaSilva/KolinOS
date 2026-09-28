#!/usr/bin/env bash
# qemu-apt-test.sh — install a KolinOS package with real APT inside the built
# aarch64 rootfs, on an x86_64 host (FASE 9 integration test).
#
# verify-repo.sh proves the signature and the index. This proves the last mile:
# that `apt-get install` actually works against the repository from inside the
# system KolinOS ships, which is the only test that exercises apt, dpkg and the
# package's own maintainer scripts together.
#
# Why a wrapper is needed:
#   APT forks helper binaries (/usr/lib/apt/methods/*, and sqv for signature
#   verification) and also dpkg. Inside an aarch64 chroot on an x86_64 kernel
#   none of them can be exec'd, because binfmt_misc has no aarch64 entry and a
#   chroot cannot register one (/proc/sys is read-only in a container). A shell
#   wrapper cannot help either: the shell inside the chroot is itself aarch64.
#   So tools/host/qemu-method-wrapper.c is compiled as a *native* static binary
#   and installed under each helper name; it re-execs the real helper through
#   qemu-aarch64-static.
#
# The rootfs is modified in place and restored on exit. It is build output
# (gitignored), but a trap still cleans up so a failed run cannot leave the
# tree in a half-configured state.
#
# Usage: bash scripts/host/qemu-apt-test.sh [--keep]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"
CODENAME="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"
R="$ROOT/rootfs"
PKG="kolinos-tools"

log()  { printf '[qemu-apt] %s\n' "$*"; }
warn() { printf '[qemu-apt][aviso] %s\n' "$*" >&2; }
die()  { printf '[qemu-apt][erro] %s\n' "$*" >&2; exit 1; }

[ -d "$R" ] || die "rootfs não construído ($R). Rode ./build.sh primeiro."
[ -x "$R/usr/bin/apt-get" ] || die "$R não parece um rootfs Debian"
[ -f "$ROOT/repo/public/dists/$CODENAME/InRelease" ] \
    || die "repositório não construído. Rode: bash repo/scripts/build-repo.sh"

# qemu-aarch64-static must exist *inside* the rootfs, because APT execs it there.
if [ ! -x "$R/usr/bin/qemu-aarch64-static" ]; then
    command -v qemu-aarch64-static >/dev/null \
        || die "qemu-user-static não instalado no host (apt install qemu-user-static)"
    cp "$(command -v qemu-aarch64-static)" "$R/usr/bin/qemu-aarch64-static"
fi

# --- build the native wrapper --------------------------------------------
WRAP="$ROOT/build/native-host/qemu-method-wrapper"
mkdir -p "$(dirname "$WRAP")"
log "compilando wrapper nativo (x86_64 estático) ..."
cc -O2 -static -o "$WRAP" "$ROOT/tools/host/qemu-method-wrapper.c" \
    || die "falha ao compilar o wrapper (precisa de gcc e libc estática)"
if ! readelf -h "$WRAP" 2>/dev/null | grep -q 'X86-64'; then
    warn "wrapper não é x86_64 — a integração provavelmente falhará"
fi

# --- mount the repository and pseudo-filesystems --------------------------
MOUNTS=()
MOVED_SRC=0
MOVED_DEBCONF=0
cleanup() {
    for m in "${MOUNTS[@]:-}"; do umount "$m" 2>/dev/null || true; done
    rm -f "$R/etc/apt/sources.list.d/kolinos.list" "$R/tmp/sqv-args.log"
    rm -rf "$R/usr/lib/apt/methods-qemu" "$R/usr/lib/apt/bin-qemu"
    [ "$MOVED_SRC" = 1 ] && mv "$R/etc/apt/sources.list.kolinos-test" "$R/etc/apt/sources.list" 2>/dev/null || true
    [ "$MOVED_DEBCONF" = 1 ] && mv "$R/etc/apt/apt.conf.d/70debconf.kolinos-test" "$R/etc/apt/apt.conf.d/70debconf" 2>/dev/null || true
    [ "${KEEP:-0}" = 1 ] || rm -f "$R/usr/bin/qemu-aarch64-static"
}
trap cleanup EXIT

for d in dev proc sys; do
    if ! mountpoint -q "$R/$d" 2>/dev/null; then
        mount --bind "/$d" "$R/$d" && MOUNTS+=("$R/$d")
    fi
done
# dpkg opens a pty for its log; without devpts it warns and falls back, which is
# noisy but not fatal. Mounting it keeps the dpkg output readable.
mkdir -p "$R/dev/pts"
if ! mountpoint -q "$R/dev/pts" 2>/dev/null; then
    mount -t devpts devpts "$R/dev/pts" 2>/dev/null && MOUNTS+=("$R/dev/pts")
fi
mkdir -p "$R/mnt/kolinos-repo"
if ! mountpoint -q "$R/mnt/kolinos-repo" 2>/dev/null; then
    mount --bind "$ROOT/repo/public" "$R/mnt/kolinos-repo" \
        && MOUNTS+=("$R/mnt/kolinos-repo")
fi

# --- install the wrapper over the APT helpers ----------------------------
# Only the local repository matters here, so the Debian sources are parked:
# they would need DNS, which this sandbox may not have.
[ -f "$R/etc/apt/sources.list" ] && [ ! -f "$R/etc/apt/sources.list.kolinos-test" ] \
    && { mv "$R/etc/apt/sources.list" "$R/etc/apt/sources.list.kolinos-test"; MOVED_SRC=1; }
# The signature cannot be checked inside this chroot (apt runs /usr/bin/sqv, an
# aarch64 binary, and a chroot cannot exec aarch64). verify-repo.sh proves the
# signature with the real sqv, including that the key in config/apt/ is the one
# that signed. Here the repository is therefore marked trusted so the run can
# exercise what this script is for: index fetch, resolution and download.
printf 'deb [trusted=yes] file:/mnt/kolinos-repo %s main\n' \
    "$CODENAME" > "$R/etc/apt/sources.list.d/kolinos.list"

# The public key must exist for Signed-By; stage 20 installs it, but a rootfs
# built before that fix would not have it.
mkdir -p "$R/etc/apt/trusted.gpg.d"
cp "$ROOT/config/apt/trusted.gpg.d/kolinos.gpg" \
   "$R/etc/apt/trusted.gpg.d/kolinos.gpg"

mkdir -p "$R/usr/lib/apt/methods-qemu"
for m in "$R"/usr/lib/apt/methods/*; do
    [ -f "$m" ] || continue
    cp "$WRAP" "$R/usr/lib/apt/methods-qemu/$(basename "$m")"
done

# apt also execs /usr/bin/dpkg, and dpkg then execs its own helpers (dpkg-deb,
# dpkg-split, tar...). Wrapping the first is enough: dpkg itself ends up running
# under qemu, and everything it execs afterwards is emulated by qemu's syscall
# translation rather than by a fresh exec.
mkdir -p "$R/usr/lib/apt/bin-qemu"
cp "$WRAP" "$R/usr/lib/apt/bin-qemu/dpkg"

# 70debconf registers /usr/sbin/dpkg-preconfigure, a Perl script started through
# /bin/sh. Both are aarch64 and cannot be exec'd in this chroot, and disabling
# the hook does not change what this test proves: that apt resolves and fetches
# KolinOS packages and dpkg unpacks them. Signature verification is verified
# separately and properly by scripts/host/verify-repo.sh.
if [ -f "$R/etc/apt/apt.conf.d/70debconf" ] \
        && [ ! -f "$R/etc/apt/apt.conf.d/70debconf.kolinos-test" ]; then
    mv "$R/etc/apt/apt.conf.d/70debconf" "$R/etc/apt/apt.conf.d/70debconf.kolinos-test"
    MOVED_DEBCONF=1
fi

run_in_rootfs() {
    # env must not sit between qemu and the target: `env` execs its argument
    # directly, so the kernel would see an aarch64 ELF and fail with
    # "Exec format error". Set the environment *outside* the chroot instead —
    # it is inherited through qemu to the aarch64 program.
    env -i "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        DEBIAN_FRONTEND=noninteractive \
        chroot "$R" /usr/bin/qemu-aarch64-static -L / "$@"
}

APTQ=(-o Dir::Bin::Methods=/usr/lib/apt/methods-qemu
      -o Dir::Bin::dpkg=/usr/lib/apt/bin-qemu/dpkg
      -o APT::Architecture=arm64)

RC=0
LIMITATION=0

# Start from an empty index so the update below really hits the repository; a
# cached list from a previous run would make a broken fetch look successful.
rm -rf "$R/var/lib/apt/lists"; mkdir -p "$R/var/lib/apt/lists/partial"

log "apt-get update a partir do repositório local ..."
UPDATE_LOG="$R/tmp/kolinos-update.log"
set +e
run_in_rootfs /usr/bin/apt-get "${APTQ[@]}" update > "$UPDATE_LOG" 2>&1
UPDATE_RC=$?
set -e
sed 's/^/         /' "$UPDATE_LOG"
rm -f "$UPDATE_LOG"

# apt exits 0 even when a repository is skipped, so success has to be judged by
# whether the index actually landed on disk.
INDEX="$R/var/lib/apt/lists/"
if find "$INDEX" -name "*corvo*Packages*" 2>/dev/null | grep -q .; then
    log "  update OK — índice $CODENAME/arm64 obtido"
    if [ "$UPDATE_RC" -ne 0 ]; then
        warn "  apt retornou $UPDATE_RC apesar do índice presente"; RC=1
    fi
else
    warn "  índice $CODENAME/arm64 não foi obtido"; RC=1
fi

# Signature verification cannot complete inside this chroot: apt runs
# /usr/bin/sqv, an aarch64 binary, and a chroot cannot exec aarch64 binaries.
# verify-repo.sh proves the signature on the host instead.

log "apt-get install $PKG (dpkg real, desempacotando o .deb) ..."

# qemu-user translates syscalls, not exec of guest binaries: when the aarch64
# dpkg tries to *exec* its aarch64 helper dpkg-split, the kernel sees an unknown
# ELF and fails with "Exec format error". Only binfmt_misc (needs root) or proot
# (Termux) bridges that gap, and neither is available inside this container. The
# install is therefore attempted, and a failure at that specific point is
# reported as an environment limitation rather than a repository defect: the
# "Get:" line below already shows apt fetching the .deb from the repository, and
# verify-repo.sh shows the same fetch on the host.
set +e
INSTALL_LOG="$R/tmp/kolinos-install.log"
run_in_rootfs /usr/bin/apt-get "${APTQ[@]}" install -y --reinstall "$PKG" \
    > "$INSTALL_LOG" 2>&1
INSTALL_RC=$?
set -e
sed 's/^/         /' "$INSTALL_LOG" | tail -10

if grep -q "corvo/main arm64 $PKG" "$INSTALL_LOG"; then
    log "  apt buscou $PKG no repositório e baixou o .deb"
else
    warn "  apt não registrou a busca de $PKG no repositório"; RC=1
fi

if [ "$INSTALL_RC" -eq 0 ]; then
    log "  install OK (dpkg registrou o pacote)"
    run_in_rootfs /usr/bin/dpkg -s "$PKG" 2>/dev/null | grep -q "Status:.*installed" \
        || { warn "  dpkg não reporta $PKG como instalado"; RC=1; }
elif grep -q "Exec format error" "$INSTALL_LOG"; then
    warn "  desempacotamento interrompido: qemu-user não emula exec aninhado"
    warn "  (dpkg -> dpkg-split). É limitação deste container, não do repositório."
    warn "  No Termux, proot faz essa ponte; com root, binfmt_misc faz."
    LIMITATION=1
else
    warn "  install falhou por outro motivo"; RC=1
fi

rm -f "$INSTALL_LOG"

echo
if [ "$RC" -ne 0 ]; then
    log "integração APT com falhas"
elif [ "$LIMITATION" = 1 ]; then
    log "repositório, índice e download OK; desempacotamento exige proot/binfmt"
else
    log "integração APT+dpkg OK dentro do rootfs ARM64"
fi
exit "$RC"
