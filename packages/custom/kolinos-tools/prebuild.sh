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

# Native C tools (stage 32). They are cross-compiled before this recipe runs,
# so they are copied from build/native/ rather than from the source tree. When
# the build host lacked a cross toolchain, stage 32 skipped and this directory
# is empty: the shell tools above then remain the only implementation, which is
# the documented fallback rather than a build failure.
if [ -d "$KOLIN_ROOT_DIR/build/native" ]; then
    install -d -m 0755 usr/bin
    for bin in "$KOLIN_ROOT_DIR"/build/native/*; do
        [ -f "$bin" ] || continue
        install -m 0755 "$bin" "usr/bin/$(basename "$bin")"
        printf 'binario nativo empacotado: %s\n' "$(basename "$bin")"
    done
fi
