#!/usr/bin/env bash
# verify-desktop.sh — sanity checks for the Corvo Glass desktop (FASE 7).
#
# Native (no root, no chroot): it inspects the built .deb files and the sources
# of the theme. Run after scripts/host/build-deb.sh.
#
# Usage:
#   bash scripts/host/verify-desktop.sh [--arch ARCH] [--rootfs DIR]
#
#   --rootfs DIR   additionally check a built rootfs tree for the desktop files
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"

ARCH="${KOLIN_DEB_ARCH:-$KOLIN_ARCH}"
DEBS="$ROOT/packages/custom/debs"
ROOTFS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   ARCH="$2"; shift 2 ;;
        --rootfs) ROOTFS="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "opção desconhecida: $1" >&2; exit 1 ;;
    esac
done

pass=0; fail=0
ok()   { printf '  \033[1;32mOK\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[1;31mFALHA\033[0m %s\n' "$*"; fail=$((fail+1)); }
head_() { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }

head_ "Pacotes do desktop (.deb $ARCH)"
for p in kolinos-theme kolinos-desktop kolinos-tools kolinos-branding; do
    f="$DEBS/${p}_${KOLIN_VERSION}-1_${ARCH}.deb"
    if [ -f "$f" ]; then ok "$(basename "$f")"; else bad "ausente: $(basename "$f") (rode build-deb.sh)"; fi
done

# --- contents of kolinos-theme --------------------------------------------
head_ "Conteúdo de kolinos-theme"
theme_deb="$DEBS/kolinos-theme_${KOLIN_VERSION}-1_${ARCH}.deb"
if [ -f "$theme_deb" ]; then
    files="$(dpkg-deb -c "$theme_deb" | awk '{print $NF}')"
    for want in \
        ./usr/share/themes/CorvoGlass/gtk-3.0/gtk.css \
        ./usr/share/themes/CorvoGlass/gtk-2.0/gtkrc \
        ./usr/share/themes/CorvoGlass/openbox-3/themerc \
        ./etc/xdg/kolinos/openbox/rc.xml \
        ./etc/xdg/kolinos/openbox/menu.xml \
        ./etc/xdg/picom/kolinos.conf \
        ./etc/xdg/tint2/kolinos.tint2rc \
        ./etc/xdg/rofi/kolinos.rasi \
        ./etc/xdg/kolinos/Xresources \
        ./usr/share/xsessions/kolinos.desktop \
        ./usr/share/applications/kolinos-terminal.desktop
    do
        if printf '%s\n' "$files" | grep -qxF "$want"; then ok "$want"; else bad "faltando em .deb: $want"; fi
    done
else
    bad "kolinos-theme .deb ausente — pulando conteúdo"
fi

# --- contents of kolinos-desktop ------------------------------------------
head_ "Conteúdo de kolinos-desktop"
desk_deb="$DEBS/kolinos-desktop_${KOLIN_VERSION}-1_${ARCH}.deb"
if [ -f "$desk_deb" ]; then
    files="$(dpkg-deb -c "$desk_deb" | awk '{print $NF}')"
    if printf '%s\n' "$files" | grep -qxF ./etc/lightdm/lightdm-gtk-greeter.conf; then
        ok "./etc/lightdm/lightdm-gtk-greeter.conf"
    else
        bad "faltando em .deb: ./etc/lightdm/lightdm-gtk-greeter.conf"
    fi
    # Must NOT own these: Debian's xinit/openbox packages do.
    for bad_path in ./etc/X11/xinit/xinitrc ./etc/xdg/openbox/rc.xml ./etc/xdg/openbox/menu.xml; do
        if printf '%s\n' "$files" | grep -qxF "$bad_path"; then
            bad "conflito com pacote Debian: $bad_path"
        else
            ok "não conflita com pacote Debian ($bad_path)"
        fi
    done
    dep="$(dpkg-deb -f "$desk_deb" Depends)"
    for d in openbox picom tint2 xterm feh rofi; do
        case "$dep" in *"$d"*) ok "depende de $d" ;; *) bad "não depende de $d" ;; esac
    done
else
    bad "kolinos-desktop .deb ausente — pulando conteúdo"
fi

# --- command-line tools in kolinos-tools ----------------------------------
head_ "Ferramentas de sessão em kolinos-tools"
tools_deb="$DEBS/kolinos-tools_${KOLIN_VERSION}-1_${ARCH}.deb"
if [ -f "$tools_deb" ]; then
    files="$(dpkg-deb -c "$tools_deb" | awk '{print $NF}')"
    for want in kolinos-session kolinos-terminal kolinos-wallpaper kolinos-launcher; do
        if printf '%s\n' "$files" | grep -qE "\./usr/bin/${want}$"; then ok "/usr/bin/$want"; else bad "faltando: /usr/bin/$want"; fi
    done
else
    bad "kolinos-tools .deb ausente — pulando ferramentas"
fi

# --- rendered assets in kolinos-branding ----------------------------------
head_ "Assets gráficos em kolinos-branding"
brand_deb="$DEBS/kolinos-branding_${KOLIN_VERSION}-1_${ARCH}.deb"
if [ -f "$brand_deb" ]; then
    files="$(dpkg-deb -c "$brand_deb" | awk '{print $NF}')"
    for want in \
        ./usr/share/backgrounds/kolinos/kolinos-corvo-mobile.png \
        ./usr/share/backgrounds/kolinos/kolinos-corvo-desktop.png \
        ./usr/share/icons/hicolor/256x256/apps/kolinos.png \
        ./etc/kolinos/branding/glass-palette.txt
    do
        if printf '%s\n' "$files" | grep -qxF "$want"; then ok "$want"; else bad "faltando em .deb: $want"; fi
    done
else
    bad "kolinos-branding .deb ausente — pulando assets"
fi

# --- config syntax sanity (from sources) ----------------------------------
head_ "Sintaxe dos configs (fontes)"
tint="$ROOT/config/desktop/tint2/kolinos.tint2rc"
if [ -f "$tint" ]; then
    # tint2 rejects these keys with a warning; catch them here instead.
    if grep -qE '^\s*background_id\s*=' "$tint"; then bad "tint2rc usa 'background_id' (inexistente no tint2 17)"; else ok "tint2rc sem background_id inválido"; fi
    if grep -qE '^\s*panel_shadow' "$tint"; then bad "tint2rc usa 'panel_shadow*' (inexistente)"; else ok "tint2rc sem panel_shadow*"; fi
    if grep -qE '^\s*clock_font\s*=' "$tint"; then bad "tint2rc usa 'clock_font' (inexistente)"; else ok "tint2rc sem clock_font"; fi
    if grep -qE '^rounded = ' "$tint"; then ok "tint2rc tem blocos de fundo"; else bad "tint2rc sem blocos de fundo"; fi
fi
pcm="$ROOT/config/desktop/picom/picom.conf"
[ -f "$pcm" ] && { grep -q 'blur-method' "$pcm" && ok "picom com blur" || bad "picom sem blur-method"; }
[ -f "$pcm" ] && { grep -q "_GTK_FRAME_EXTENTS@:c" "$pcm" && bad "picom usa ':_c' depreciado" || ok "picom sem ':c' depreciado"; }
g3="$ROOT/config/desktop/gtk-3.0/gtk.css"
[ -f "$g3" ] && { grep -q 'glass' "$g3" && ok "gtk.css com superfícies de vidro" || bad "gtk.css sem vidro"; }

# --- palette tokens reach the SVG sources ---------------------------------
head_ "Paleta (tokens nos SVGs)"
for s in emblem.svg wallpaper-mobile.svg wallpaper-desktop.svg; do
    f="$ROOT/config/branding/$s"
    if [ -f "$f" ] && grep -q '@KOLIN_GLASS_PRIMARY@' "$f"; then ok "$s usa tokens da paleta"; else bad "$s sem tokens @KOLIN_GLASS_*@"; fi
done

# --- optional: rootfs tree -------------------------------------------------
if [ -n "$ROOTFS" ]; then
    head_ "Árvore do rootfs: $ROOTFS"
    for f in \
        usr/bin/kolinos-session usr/bin/kolinos-terminal \
        usr/share/themes/CorvoGlass/gtk-3.0/gtk.css \
        usr/share/themes/CorvoGlass/openbox-3/themerc \
        etc/xdg/picom/kolinos.conf etc/xdg/tint2/kolinos.tint2rc \
        usr/share/xsessions/kolinos.desktop \
        usr/share/backgrounds/kolinos/kolinos-corvo-mobile.png
    do
        if [ -e "$ROOTFS/$f" ]; then ok "/$f"; else bad "ausente no rootfs: /$f"; fi
    done
    if [ -x "$ROOTFS/usr/bin/kolinos-session" ]; then ok "kolinos-session executável"; else bad "kolinos-session não executável"; fi
fi

head_ "Resumo"
printf '  %d OK, %d falha(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
