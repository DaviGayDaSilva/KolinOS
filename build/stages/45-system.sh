#!/usr/bin/env bash
# Stage 45 — normalise the minimal base: locale, fstab, machine-id, resolv.conf.
# Runs after packages (30) and before user creation (50).
stage_main() {
    local r="$KOLIN_ROOTFS"

    # Drop leftovers the unpack-time dpkg filter cannot catch.
    kolin_slim_sweep "$r"

    # --- locale -----------------------------------------------------------
    # C.UTF-8 is compiled into glibc and needs no generation. Any other locale
    # must exist in /usr/share/i18n/locales and be generated with locale-gen.
    printf 'LANG=%s\n' "$KOLIN_LOCALE" > "$r/etc/default/locale"
    printf 'LANG=%s\n' "$KOLIN_LOCALE" > "$r/etc/environment"
    local loc_base="${KOLIN_LOCALE%%.*}"
    if [ "$KOLIN_LOCALE" != "C.UTF-8" ] && [ -f "$r/usr/share/i18n/locales/$loc_base" ]; then
        log "gerando locale $KOLIN_LOCALE ..."
        kolin_run "$r" "grep -q '^${loc_base} ' /etc/locale.gen 2>/dev/null || printf '%s UTF-8\n' '${loc_base}' >> /etc/locale.gen; locale-gen"
    else
        log "locale ${KOLIN_LOCALE} (gerado no glibc, sem locale-gen)"
    fi

    # --- fstab ------------------------------------------------------------
    # Not used by proot/chroot; kept for real hardware (Phase 10) and tools
    # that expect the file to exist.
    cat > "$r/etc/fstab" <<'EOF'
# /etc/fstab — KolinOS static filesystem information.
# In containers (Termux/proot) and chroot this file is not consulted.
# <file system>  <mount point>  <type>  <options>  <dump>  <pass>
EOF

    # --- machine-id -------------------------------------------------------
    # Empty file: systemd/derived tooling generates the real id on first boot.
    : > "$r/etc/machine-id"
    if [ -d "$r/var/lib/dbus" ]; then
        rm -f "$r/var/lib/dbus/machine-id"
        ln -sf /etc/machine-id "$r/var/lib/dbus/machine-id"
    fi

    # --- resolv.conf ------------------------------------------------------
    # Managed at runtime: proot-distro writes it from Android; a network
    # manager/DHCP does it on real hardware. Ship it empty, not the host's.
    cat > "$r/etc/resolv.conf" <<'EOF'
# KolinOS: /etc/resolv.conf is managed at runtime.
EOF

    log "base de sistema normalizada (locale, fstab, machine-id, resolv.conf)"
}
