#!/usr/bin/env bash
# preview-theme.sh — render the Corvo Glass theme in a headless X server and
# take a screenshot. Development/QA helper (FASE 7): it does not build anything
# and is not part of the shipped system.
#
# It installs the theme files into a temporary prefix, starts Xvfb + openbox +
# picom + tint2, opens a terminal and a GTK demo window, then saves a PNG.
#
# Requirements (Debian): xvfb openbox picom tint2 xterm feh imagemagick
#                        fonts-inter fonts-jetbrains-mono gtk-3-examples rofi
#
# Usage: bash scripts/host/preview-theme.sh [OUTPUT_PNG]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"

OUT="${1:-$ROOT/output/desktop/preview-desktop.png}"
D="$ROOT/config/desktop"
DISP=":${KOLIN_PREVIEW_DISPLAY:-97}"
PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-preview.XXXXXX")"
GEOM="${KOLIN_PREVIEW_GEOM:-1280x800}"

log() { printf '[preview] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
for t in Xvfb openbox picom tint2 xterm import feh; do
    have "$t" || { echo "[preview][erro] falta '$t'" >&2; exit 1; }
done

cleanup() {
    set +e
    [ -n "${XPID:-}"  ] && kill "$XPID"  2>/dev/null
    [ -n "${OBPID:-}" ] && kill "$OBPID" 2>/dev/null
    [ -n "${PCPID:-}" ] && kill "$PCPID" 2>/dev/null
    [ -n "${T2PID:-}" ] && kill "$T2PID" 2>/dev/null
    rm -rf "$PREFIX"
}
trap cleanup EXIT

# --- stage the theme into a prefix ----------------------------------------
install -d "$PREFIX/usr/share/themes/CorvoGlass/gtk-3.0" \
           "$PREFIX/usr/share/themes/CorvoGlass/gtk-2.0" \
           "$PREFIX/usr/share/themes/CorvoGlass/openbox-3" \
           "$PREFIX/etc/xdg/kolinos/openbox" "$PREFIX/etc/xdg/picom" \
           "$PREFIX/etc/xdg/tint2" "$PREFIX/etc/xdg/rofi" \
           "$PREFIX/etc/xdg/kolinos" "$PREFIX/usr/share/backgrounds/kolinos"
cp "$D/index.theme" "$PREFIX/usr/share/themes/CorvoGlass/"
cp "$D/gtk-3.0/gtk.css" "$PREFIX/usr/share/themes/CorvoGlass/gtk-3.0/"
cp "$D/gtk-2.0/gtkrc"  "$PREFIX/usr/share/themes/CorvoGlass/gtk-2.0/"
cp "$D/openbox/themes/CorvoGlass/openbox-3/themerc" "$PREFIX/usr/share/themes/CorvoGlass/openbox-3/"
cp "$D/openbox/rc.xml" "$PREFIX/etc/xdg/kolinos/openbox/rc.xml"
cp "$D/openbox/menu.xml" "$PREFIX/etc/xdg/kolinos/openbox/menu.xml"
cp "$D/picom/picom.conf" "$PREFIX/etc/xdg/picom/kolinos.conf"
cp "$D/tint2/kolinos.tint2rc" "$PREFIX/etc/xdg/tint2/kolinos.tint2rc"
cp "$D/rofi/kolinos.rasi" "$PREFIX/etc/xdg/rofi/kolinos.rasi"
cp "$D/xresources/KolinOS.Xresources" "$PREFIX/etc/xdg/kolinos/Xresources"

# Application entries so tint2's launchers and rofi resolve inside the prefix.
install -d "$PREFIX/usr/share/applications"
cp "$D/applications/"*.desktop "$PREFIX/usr/share/applications/" 2>/dev/null || true

export XDG_CONFIG_DIRS="$PREFIX/etc/xdg:/etc/xdg"
export XDG_DATA_DIRS="$PREFIX/usr/share:/usr/share"
export GTK_THEME=CorvoGlass
export GTK2_RC_FILES="$PREFIX/usr/share/themes/CorvoGlass/gtk-2.0/gtkrc"

WALL="$ROOT/output/desktop/wallpapers/kolinos-corvo-desktop.png"
case "$GEOM" in
    *x*) w="${GEOM%x*}"; h="${GEOM#*x}" ;;
esac
if [ -n "${w:-}" ] && [ -n "${h:-}" ] && [ "$h" -gt "$w" ]; then
    WALL="$ROOT/output/desktop/wallpapers/kolinos-corvo-mobile.png"
fi
[ -f "$WALL" ] || bash "$ROOT/scripts/artifacts/render-assets.sh" "$ROOT/output/desktop" >/dev/null

# --- start the X server ----------------------------------------------------
log "iniciando Xvfb $DISP ($GEOM)"
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp >/tmp/kolinos-preview-xvfb.log 2>&1 &
XPID=$!
for _ in $(seq 1 40); do xdpyinfo -display "$DISP" >/dev/null 2>&1 && break; sleep 0.25; done
export DISPLAY="$DISP"

xrdb -merge "$PREFIX/etc/xdg/kolinos/Xresources" 2>/dev/null || true
feh --bg-fill "$WALL" >/dev/null 2>&1 || true

log "iniciando compositor, painel e WM"
picom --config "$PREFIX/etc/xdg/picom/kolinos.conf" >/tmp/kolinos-preview-picom.log 2>&1 &
PCPID=$!
sleep 1
tint2 -c "$PREFIX/etc/xdg/tint2/kolinos.tint2rc" >/tmp/kolinos-preview-tint2.log 2>&1 &
T2PID=$!
openbox --config-file "$PREFIX/etc/xdg/kolinos/openbox/rc.xml" >/tmp/kolinos-preview-openbox.log 2>&1 &
OBPID=$!
sleep 2

# --- window content --------------------------------------------------------
# A terminal printing the brand summary, plus a GTK3 widget demo to show the
# theme on real widgets.
gen_demo() {
    cat > "$PREFIX/demo.sh" <<'EOS'
#!/usr/bin/env bash
clear
printf '\033[38;5;99m\033[1m'
cat <<'ART'
        ▄▄▄▄▄▄▄▄▄▄▄
      ▄█████████████████▄
    ▄█████▀▀         ▀▀█████▄
   ██████     ◆     ◆     ██████
   ██████        ◆◆        ██████
   ██████▄                 ▄██████
    ▀██████▄▄         ▄▄██████▀
      ▀▀█████████████████▀▀
          ▀▀▀▀▀▀▀▀▀▀▀▀▀
ART
printf '\033[0m'
printf '\033[38;5;44m  KolinOS 1.0.0 (Corvo) — aarch64\033[0m\n'
printf '  \033[38;5;245mDebian 13 trixie · 170 pacotes · Corvo Glass\033[0m\n\n'
printf '\033[38;5;76mkolin@kolinos\033[0m:\033[38;5;99m~\033[0m$ kolinos-info\n'
printf '  \033[38;5;245mtema: CorvoGlass · compositor: picom · WM: openbox\033[0m\n'
printf '\033[38;5;76mkolin@kolinos\033[0m:\033[38;5;99m~\033[0m$ ▊\n'
sleep 30
EOS
    chmod +x "$PREFIX/demo.sh"
}
gen_demo
xterm -class XTerm -fa 'JetBrains Mono' -fs 11 -bg '#0C0A16' -fg '#F5F3FF' \
      -geometry 92x26+40+120 -e "$PREFIX/demo.sh" >/dev/null 2>&1 &
XTPID=$!

if have gtk3-widget-factory; then
    gtk3-widget-factory >/dev/null 2>&1 &
    sleep 3
fi
sleep 2

# Raise/blur the terminal so the glass effect is visible over the wallpaper.
if have xdotool; then
    WID="$(xdotool search --class XTerm | tail -1)"
    [ -n "$WID" ] && xdotool windowactivate "$WID" 2>/dev/null || true
fi

mkdir -p "$(dirname "$OUT")"
log "capturando $OUT"
import -window root "$OUT"
kill "$XTPID" 2>/dev/null || true
log "pronto: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
