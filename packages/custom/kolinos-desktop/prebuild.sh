#!/usr/bin/env bash
# Assemble the kolinos-desktop payload. The metapackage itself ships only
# integration glue (login greeter theme + an xinit entry point); the window
# manager, compositor, panel and terminal all arrive as dependencies.
set -euo pipefail

: "${KOLIN_ROOT_DIR:?KOLIN_ROOT_DIR not set}"
D="$KOLIN_ROOT_DIR/config/desktop"

# --- lightdm greeter: Corvo Glass look on the login screen -----------------
install -D -m 0644 "$D/lightdm/greeter.conf" etc/lightdm/lightdm-gtk-greeter.conf

# NOTE: this package intentionally does NOT ship /etc/X11/xinit/xinitrc — the
# Debian `xinit` package owns that path as a conffile and owning it here makes
# dpkg abort openbox's unpack ("trying to overwrite ..."). Users starting an X
# session by hand run `kolinos-session` (or put it in ~/.xinitrc); display
# managers pick the session up from /usr/share/xsessions/kolinos.desktop.
