#!/usr/bin/env bash
# Assemble the payload from the repository tree (single source of truth).
set -euo pipefail

: "${KOLIN_ROOT_DIR:?KOLIN_ROOT_DIR not set}"

install -d -m 0755 etc/kolinos/branding
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/logo.txt"       etc/kolinos/branding/logo.txt
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/logo-small.txt" etc/kolinos/branding/logo-small.txt
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/palette.txt"    etc/kolinos/branding/palette.txt
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/glass-palette.txt" etc/kolinos/branding/glass-palette.txt
# Rendered by build-deb.sh (@KOLIN_COLOR_*@ come from VERSION).
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/colors.sh.in"   etc/kolinos/colors.sh

# --- graphical assets (FASE 7) --------------------------------------------
# Render the SVG sources here, inside the recipe, so this package does not
# depend on the build stage order (stage 35 builds .debs before the graphics
# stage). If rsvg-convert is unavailable the package still builds, just without
# the raster assets — the session degrades gracefully.
if command -v rsvg-convert >/dev/null 2>&1; then
    assets="$(mktemp -d)"
    KOLIN_ASSETS_DIR="$assets" bash "$KOLIN_ROOT_DIR/scripts/artifacts/render-assets.sh" "$assets" >/dev/null
    install -d -m 0755 usr/share/backgrounds/kolinos
    install -m 0644 "$assets/wallpapers/kolinos-corvo-mobile.png"  usr/share/backgrounds/kolinos/
    install -m 0644 "$assets/wallpapers/kolinos-corvo-desktop.png" usr/share/backgrounds/kolinos/
    install -d -m 0755 usr/share/pixmaps
    install -m 0644 "$assets/logo/kolinos-emblem-256.png" usr/share/pixmaps/kolinos.png
    for size in 512 256 128 64 48 32; do
        install -D -m 0644 "$assets/icons/hicolor/${size}x${size}/apps/kolinos.png" \
            "usr/share/icons/hicolor/${size}x${size}/apps/kolinos.png"
    done
    rm -rf "$assets"
else
    echo "[branding][aviso] rsvg-convert ausente: assets graficos nao incluidos" >&2
fi
