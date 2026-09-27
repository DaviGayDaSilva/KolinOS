#!/usr/bin/env bash
# build-deb.sh — build a KolinOS .deb from a package recipe (FASE 5).
#
# A "recipe" is a directory under packages/custom/<name>/ with a debian/
# subdirectory (control, changelog, optionally postinst/...) plus the payload
# files laid out exactly as they should land on the target filesystem
# (e.g. usr/bin/foo, etc/foo/bar). This is the source-tree/staging-package
# form, and dpkg-deb turns it into a real Debian binary package.
#
# The build is deterministic: SOURCE_DATE_EPOCH plus a fixed mtime on every
# file and --root-owner-group make two builds of the same recipe byte-identical
# (same idea already used for the rootfs in FASE 4).
#
# Usage:
#   sudo bash scripts/host/build-deb.sh [RECIPE_DIR]
#   sudo bash scripts/host/build-deb.sh            # builds every recipe
#
# Environment:
#   SOURCE_DATE_EPOCH   fixed timestamp (default: the git commit date, or the
#                       KOLIN_BUILD_EPOCH value from VERSION if set)
#   KOLIN_DEB_ARCH      architecture field (default: the value from VERSION)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '[deb] %s\n' "$*"; }
warn() { printf '[deb][aviso] %s\n' "$*" >&2; }
die()  { printf '[deb][erro] %s\n' "$*" >&2; exit 1; }

have dpkg-deb || die "dpkg-deb ausente (instale 'dpkg')"

ARCH="${KOLIN_DEB_ARCH:-$KOLIN_ARCH}"
DEBS_DIR="$ROOT/packages/custom/debs"
mkdir -p "$DEBS_DIR"

# Deterministic timestamp: explicit > VERSION > git commit date > wall clock.
stamp="${SOURCE_DATE_EPOCH:-${KOLIN_BUILD_EPOCH:-}}"
if [ -z "$stamp" ]; then
    stamp="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || true)"
fi
[ -n "$stamp" ] || stamp="$(date -u +%s)"
export SOURCE_DATE_EPOCH="$stamp"

# shellcheck disable=SC2016  # the trailing command is expanded inside a subshell
replace_tokens() { # <file>  — substitute @KOLIN_*@ with values from VERSION/env
    local f="$1" line key val
    while IFS= read -r line; do
        case "$line" in KOLIN*=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        val="${val%%[[:space:]]#*}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val%\"}"; val="${val#\"}"
        sed -i "s|@${key}@|${val}|g" "$f"
    done < <(grep -E '^KOLIN[A-Z_]*=' "$ROOT/VERSION")
    sed -i "s|@KOLIN_CODENAME_LOWER@|$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')|g" "$f"
    sed -i "s|@KOLIN_DEB_ARCH@|${ARCH}|g" "$f"
}

build_one() { # <recipe-dir>
    local recipe="$1" name deb
    name="$(basename "$recipe")"
    [ -d "$recipe/debian" ] || die "receita '$name' sem diretório debian/"
    [ -f "$recipe/debian/control" ] || die "receita '$name' sem debian/control"

    # Work on a copy: debian/ lives in the recipe, and we never mutate the
    # source tree (only the copy gets stamped and token-rendered).
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-deb.XXXXXX")"
    trap 'rm -rf "$work"' RETURN
    cp -a "$recipe/." "$work/"
    rm -rf "$work/debian/debs"   # never package a previous output

    # prebuild.sh lets a recipe assemble its payload from the repository tree
    # (tools/, config/) instead of duplicating files. It runs in the work dir
    # and is removed before packaging so it never becomes payload.
    if [ -f "$work/prebuild.sh" ]; then
        log "$name: prebuild.sh"
        ( cd "$work" && KOLIN_ROOT_DIR="$ROOT" KOLIN_VERSION="$KOLIN_VERSION" \
            KOLIN_CODENAME="$KOLIN_CODENAME" bash ./prebuild.sh ) \
            || die "$name: prebuild.sh falhou"
    fi
    rm -f "$work/prebuild.sh"

    # Make the package version agree with the project version, unless the
    # recipe pins its own (Version: present in control).
    if ! grep -qiE '^Version:' "$work/debian/control"; then
        printf 'Version: %s-1\n' "$KOLIN_VERSION" >> "$work/debian/control"
    fi

    # Render @KOLIN_*@ tokens in control, changelog and maintainer scripts.
    local f
    while IFS= read -r -d '' f; do replace_tokens "$f"; done \
        < <(find "$work/debian" -maxdepth 1 -type f -print0)
    while IFS= read -r -d '' f; do replace_tokens "$f"; done \
        < <(find "$work" -mindepth 1 -path "$work/debian" -prune -o -type f -print0)

    # dpkg-deb expects the control directory in upper case (DEBIAN/), while
    # recipes keep the familiar lower-case debian/ (as dpkg-source does). It is
    # rebuilt in a fresh directory: a source checkout may carry a setgid bit
    # (set by the repo's group-writable dirs) that dpkg-deb rejects and that
    # chmod cannot always clear.
    mv "$work/debian" "$work/.control-src"
    mkdir -p "$work/DEBIAN"
    cp "$work"/.control-src/* "$work/DEBIAN/"
    rm -rf "$work/.control-src"
    # A source checkout may carry setgid bits on directories (group-writable
    # repos do this); dpkg-deb rejects them and a plain "chmod 0755" does not
    # always clear them, so drop the bit explicitly on every directory.
    find "$work" -type d -exec chmod g-s {} +
    chmod 0755 "$work/DEBIAN"
    chmod 0644 "$work"/DEBIAN/* 2>/dev/null || true
    for s in postinst preinst postrm prerm config triggers; do
        [ -f "$work/DEBIAN/$s" ] && chmod 0755 "$work/DEBIAN/$s"
    done

    # Auto-generate debian/md5sums and Installed-Size from the actual payload,
    # so a recipe author cannot forget them (dpkg-verify relies on md5sums).
    local payload
    payload="$(du -sk --exclude="$work/DEBIAN" "$work" 2>/dev/null | awk '{print $1}')"
    if ! grep -qiE '^Installed-Size:' "$work/DEBIAN/control"; then
        printf 'Installed-Size: %s\n' "$payload" >> "$work/DEBIAN/control"
    fi
    if [ ! -f "$work/DEBIAN/md5sums" ]; then
        # dpkg requires exactly two spaces between the hash and the path
        # (md5sum emits two; normalise in case a path has odd spacing).
        ( cd "$work" && find . -path ./DEBIAN -prune -o -type f -print0 \
            | sed -z 's|^\./||' | sort -z \
            | xargs -0 -r md5sum | sed 's|  *|  |' ) > "$work/DEBIAN/md5sums" 2>/dev/null || true
    fi

    # Reproducibility: one fixed timestamp on every entry, kept owner/group.
    find "$work" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

    deb="$DEBS_DIR/${name}_${KOLIN_VERSION}-1_${ARCH}.deb"
    rm -f "$deb"
    dpkg-deb --root-owner-group -Zxz --build "$work" "$deb" >/dev/null
    log "gerado: $(basename "$deb") ($(du -h "$deb" | awk '{print $1}'))"

    # Record the architecture so a cross build cannot silently ship the wrong one.
    local got
    got="$(dpkg-deb -f "$deb" Architecture)"
    [ "$got" = "$ARCH" ] || die "arquitetura errada em $(basename "$deb"): $got (esperado $ARCH)"
}

mapfile -t recipes < <(find "$ROOT/packages/custom" -mindepth 1 -maxdepth 1 -type d -name '[!_]*' ! -name debs | sort)
if [ "$#" -gt 0 ]; then
    recipes=("$1")
fi
[ "${#recipes[@]}" -gt 0 ] || die "nenhuma receita em packages/custom/"

for r in "${recipes[@]}"; do
    build_one "$r"
done

log "pacotes em $DEBS_DIR"
ls -1 "$DEBS_DIR"/*.deb 2>/dev/null | sed 's|.*/|  |'
