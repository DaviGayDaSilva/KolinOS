#!/usr/bin/env bash
# Assemble the payload from the repository tree (single source of truth).
set -euo pipefail

: "${KOLIN_ROOT_DIR:?KOLIN_ROOT_DIR not set}"

install -d -m 0755 etc/kolinos/branding
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/logo.txt"       etc/kolinos/branding/logo.txt
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/logo-small.txt" etc/kolinos/branding/logo-small.txt
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/palette.txt"    etc/kolinos/branding/palette.txt
# Rendered by build-deb.sh (@KOLIN_COLOR_*@ come from VERSION).
install -m 0644 "$KOLIN_ROOT_DIR/config/branding/colors.sh.in"   etc/kolinos/colors.sh
