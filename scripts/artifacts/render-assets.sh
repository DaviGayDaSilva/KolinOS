#!/usr/bin/env bash
# render-assets.sh — render KolinOS SVG sources into PNG/icon assets (FASE 7).
#
# The SVGs in config/branding/ carry @KOLIN_GLASS_*@ colour tokens; this script
# substitutes them from VERSION and rasterises with rsvg-convert. Rasterising at
# build time (not shipping PNGs in the source tree) keeps the palette as the
# single source of truth: changing a colour in VERSION changes every wallpaper,
# icon and logo on the next build.
#
# Usage:
#   bash scripts/artifacts/render-assets.sh [OUTPUT_DIR]   (default: ./output/desktop)
#
# Environment:
#   KOLIN_ASSETS_DIR   override the destination
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"

BRAND="$ROOT/config/branding"
OUT="${1:-${KOLIN_ASSETS_DIR:-$ROOT/output/desktop}}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-assets.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

log() { printf '[assets] %s\n' "$*"; }
die() { printf '[assets][erro] %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
need_render=0
for f in "$BRAND"/emblem.svg "$BRAND"/wallpaper-mobile.svg "$BRAND"/wallpaper-desktop.svg; do
    [ -f "$f" ] && need_render=1
done
if [ "$need_render" = 1 ]; then
    have rsvg-convert || die "rsvg-convert ausente (Debian: apt install librsvg2-bin)"
fi

mkdir -p "$OUT/wallpapers" "$OUT/icons" "$OUT/logo"

# Substitute @KOLIN_GLASS_*@ and the project identity tokens in one pass.
render_svg() { # <src.svg> <dst.svg>
    local src="$1" dst="$2" line key val
    cp "$src" "$dst"
    while IFS= read -r line; do
        case "$line" in KOLIN*=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        val="${val%%[[:space:]]#*}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val%\"}"; val="${val#\"}"
        sed -i "s|@${key}@|${val}|g" "$dst"
    done < <(grep -E '^KOLIN[A-Z_]*=' "$ROOT/VERSION")
}

png() { # <svg> <png> <width>
    rsvg-convert -w "$3" -o "$2" "$1"
    log "$(basename "$2")  $(du -h "$2" | awk '{print $1}')"
}

# --- emblem / logo ---------------------------------------------------------
if [ -f "$BRAND/emblem.svg" ]; then
    render_svg "$BRAND/emblem.svg" "$STAGE/emblem.svg"
    png "$STAGE/emblem.svg" "$OUT/logo/kolinos-emblem-512.png" 512
    png "$STAGE/emblem.svg" "$OUT/logo/kolinos-emblem-256.png" 256
    png "$STAGE/emblem.svg" "$OUT/logo/kolinos-emblem-128.png" 128
    png "$STAGE/emblem.svg" "$OUT/logo/kolinos-emblem-64.png"  64
    png "$STAGE/emblem.svg" "$OUT/logo/kolinos-emblem-32.png"  32
    png "$STAGE/emblem.svg" "$OUT/logo/kolinos-emblem-16.png"  16

    # Icon themes look up 'kolinos' by name; ship the common sizes.
    install -d "$OUT/icons/hicolor/512x512/apps" "$OUT/icons/hicolor/256x256/apps" \
               "$OUT/icons/hicolor/128x128/apps" "$OUT/icons/hicolor/64x64/apps" \
               "$OUT/icons/hicolor/48x48/apps"   "$OUT/icons/hicolor/32x32/apps"
    for s in 512 256 128 64 48 32; do
        if [ "$s" = 48 ]; then png "$STAGE/emblem.svg" "$OUT/icons/hicolor/${s}x${s}/apps/kolinos.png" "$s"; continue; fi
        cp "$OUT/logo/kolinos-emblem-$s.png" "$OUT/icons/hicolor/${s}x${s}/apps/kolinos.png"
    done
fi

# --- wallpapers ------------------------------------------------------------
if [ -f "$BRAND/wallpaper-mobile.svg" ]; then
    render_svg "$BRAND/wallpaper-mobile.svg" "$STAGE/wall-mobile.svg"
    png "$STAGE/wall-mobile.svg"  "$OUT/wallpapers/kolinos-corvo-mobile.png"  1080
fi
if [ -f "$BRAND/wallpaper-desktop.svg" ]; then
    render_svg "$BRAND/wallpaper-desktop.svg" "$STAGE/wall-desktop.svg"
    png "$STAGE/wall-desktop.svg" "$OUT/wallpapers/kolinos-corvo-desktop.png" 1920
fi

log "assets em $OUT"
