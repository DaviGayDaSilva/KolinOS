#!/usr/bin/env bash
# Assemble the payload from the repository tree (single source of truth).
# Runs with the recipe as the working directory, before packaging.
set -euo pipefail

: "${KOLIN_ROOT_DIR:?KOLIN_ROOT_DIR not set}"

install -d -m 0755 usr/bin
install -m 0755 "$KOLIN_ROOT_DIR/tools/kolinos-info"     usr/bin/kolinos-info
install -m 0755 "$KOLIN_ROOT_DIR/tools/kolinos-version"  usr/bin/kolinos-version
install -m 0755 "$KOLIN_ROOT_DIR/tools/apt-kolinos"      usr/bin/apt-kolinos
install -m 0755 "$KOLIN_ROOT_DIR/tools/kolinos-firstboot" usr/bin/kolinos-firstboot
install -m 0755 "$KOLIN_ROOT_DIR/tools/kolinos-session"  usr/bin/kolinos-session
install -m 0755 "$KOLIN_ROOT_DIR/tools/kolinos-terminal" usr/bin/kolinos-terminal
install -m 0755 "$KOLIN_ROOT_DIR/tools/kolinos-wallpaper" usr/bin/kolinos-wallpaper
install -m 0755 "$KOLIN_ROOT_DIR/tools/kolinos-launcher" usr/bin/kolinos-launcher
