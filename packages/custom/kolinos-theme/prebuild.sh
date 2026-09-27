#!/usr/bin/env bash
# Assemble the kolinos-theme payload from the repository tree (single source of
# truth). Runs with the recipe as the working directory, before packaging.
set -euo pipefail

: "${KOLIN_ROOT_DIR:?KOLIN_ROOT_DIR not set}"

D="$KOLIN_ROOT_DIR/config/desktop"

# --- GTK 2/3 + theme index -------------------------------------------------
install -D -m 0644 "$D/index.theme"                usr/share/themes/CorvoGlass/index.theme
install -D -m 0644 "$D/gtk-3.0/gtk.css"            usr/share/themes/CorvoGlass/gtk-3.0/gtk.css
install -D -m 0644 "$D/gtk-2.0/gtkrc"              usr/share/themes/CorvoGlass/gtk-2.0/gtkrc
install -D -m 0644 "$D/gtk-3.0/settings.ini"       usr/share/themes/CorvoGlass/gtk-3.0/settings.ini
install -D -m 0644 "$D/openbox/themes/CorvoGlass/openbox-3/themerc" \
                                                   usr/share/themes/CorvoGlass/openbox-3/themerc

# --- system-wide app defaults ----------------------------------------------
install -D -m 0644 "$D/gtk-3.0/settings.ini"       etc/gtk-3.0/settings.ini

# --- desktop configuration (one dir per component) -------------------------
# Openbox's own package owns /etc/xdg/openbox/{rc,menu}.xml as conffiles, so
# shipping at those exact paths makes dpkg refuse to unpack openbox ("trying to
# overwrite ... which is also in package kolinos-theme"). The themed config goes
# to a private directory instead and is selected explicitly by kolinos-session
# via `openbox --config-file`; openbox then loads menu.xml from the same dir.
install -D -m 0644 "$D/openbox/rc.xml"             etc/xdg/kolinos/openbox/rc.xml
install -D -m 0644 "$D/openbox/menu.xml"           etc/xdg/kolinos/openbox/menu.xml
install -D -m 0644 "$D/picom/picom.conf"           etc/xdg/picom/kolinos.conf
install -D -m 0644 "$D/tint2/kolinos.tint2rc"      etc/xdg/tint2/kolinos.tint2rc
install -D -m 0644 "$D/rofi/kolinos.rasi"          etc/xdg/rofi/kolinos.rasi
install -D -m 0644 "$D/xresources/KolinOS.Xresources" etc/xdg/kolinos/Xresources
install -D -m 0644 "$D/foot/kolinos.ini"           etc/xdg/foot/kolinos.ini

# --- default applications / session ----------------------------------------
install -D -m 0644 "$D/session/kolinos.desktop"       usr/share/xsessions/kolinos.desktop
install -D -m 0644 "$D/applications/kolinos-terminal.desktop" usr/share/applications/kolinos-terminal.desktop
install -D -m 0644 "$D/applications/kolinos-launcher.desktop" usr/share/applications/kolinos-launcher.desktop
