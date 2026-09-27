#!/usr/bin/env bash
# Stage 65 — graphical session (FASE 7): "Corvo Glass".
#
# The packages themselves are installed by stage 35 (kolinos-desktop +
# kolinos-theme, pulled from the local APT repository with their Debian
# dependency set). This stage only verifies the result and applies the few
# settings that must be written into the rootfs directly.
#
# It does NOT install a display server and does NOT try to start anything.
# A graphical session needs an X server, which is environment-specific:
#   * real hardware : an Xorg server (package xserver-xorg) or lightdm;
#   * Termux/Android: the Termux:X11 app — see docs/PHASE7.md.
# Nothing here requires root on the device (proot included); mounting a real X
# server does, and that is out of this stage's scope.
stage_main() {
    local r="$KOLIN_ROOTFS"

    if [ "${KOLIN_DESKTOP:-0}" != 1 ]; then
        log "desktop desativado (use --with-desktop para incluir o Corvo Glass)"
        return 0
    fi

    # The session must be present; without it --with-desktop did nothing useful.
    if [ ! -x "$r/usr/bin/kolinos-session" ]; then
        die "kolinos-session ausente: o pacote kolinos-desktop/kolinos-tools não foi instalado"
    fi

    # --- verify the key files landed in the rootfs -------------------------
    local missing=0 f
    for f in \
        usr/share/themes/CorvoGlass/gtk-3.0/gtk.css \
        usr/share/themes/CorvoGlass/gtk-2.0/gtkrc \
        usr/share/themes/CorvoGlass/openbox-3/themerc \
        etc/xdg/kolinos/openbox/rc.xml \
        etc/xdg/picom/kolinos.conf \
        etc/xdg/tint2/kolinos.tint2rc \
        etc/xdg/rofi/kolinos.rasi \
        etc/xdg/kolinos/Xresources \
        usr/share/xsessions/kolinos.desktop \
        usr/share/backgrounds/kolinos/kolinos-corvo-mobile.png \
        usr/share/backgrounds/kolinos/kolinos-corvo-desktop.png
    do
        [ -e "$r/$f" ] || { warn "arquivo do tema ausente: /$f"; missing=1; }
    done
    [ "$missing" -eq 0 ] || die "instalação do desktop incompleta (veja avisos acima)"

    # --- default wallpaper + theme for the first user ----------------------
    # A user-level config makes the session remember the wallpaper and GTK
    # theme before any settings daemon runs. Written for the default user and
    # for root so the look is right whichever account logs in.
    local u
    for u in root "${KOLIN_DEFAULT_USER}"; do
        local home="$r/home/$u"
        [ "$u" = root ] && home="$r/root"
        [ -d "$home" ] || continue
        install -d -m 0755 "$home/.config/gtk-3.0"
        cat > "$home/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=CorvoGlass
gtk-icon-theme-name=hicolor
gtk-font-name=Inter 10
gtk-application-prefer-dark-theme=1
EOF
        # Marker read by kolinos-session to apply the wallpaper on first run.
        install -d -m 0755 "$home/.config/kolinos"
        printf 'wallpaper=kolinos-corvo-mobile.png\n' > "$home/.config/kolinos/desktop.conf"
    done

    # --- enable lightdm automatically only if the user installed it --------
    # lightdm is a Suggests, so it is usually absent. If present, make it the
    # default display manager so the Corvo Glass greeter is used.
    if [ -e "$r/usr/sbin/lightdm" ]; then
        mkdir -p "$r/etc/X11"
        printf '/usr/sbin/lightdm\n' > "$r/etc/X11/default-display-manager"
        log "lightdm detectado: definido como display manager padrão"
    else
        log "lightdm ausente: inicie a sessão com 'kolinos-session' ou 'startx'"
    fi

    # --- report -------------------------------------------------------------
    local debs
    debs="$(kolin_run "$r" "dpkg-query -W -f='\${Package} \${Version}\n' \
        kolinos-desktop kolinos-theme openbox picom tint2 xterm 2>/dev/null | sort")" || true
    log "sessão gráfica Corvo Glass instalada:"
    printf '%s\n' "$debs" | sed 's/^/  /'
    log "para iniciar (com um servidor X ativo): kolinos-session"
}
