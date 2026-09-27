#!/usr/bin/env bash
# Stage 40 — apply KolinOS identity, branding and default system configuration.
stage_main() {
    local r="$KOLIN_ROOTFS"

    # --- hostname & hosts -------------------------------------------------
    printf '%s\n' "$KOLIN_HOSTNAME" > "$r/etc/hostname"
    cat > "$r/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${KOLIN_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # --- identity files ---------------------------------------------------
    render_template "$KOLIN_ROOT_DIR/config/os-release.in" "$r/etc/os-release"
    render_template "$KOLIN_ROOT_DIR/config/os-release.in" "$r/usr/lib/os-release"
    render_template "$KOLIN_ROOT_DIR/config/motd/00-header" "$r/etc/motd"
    mkdir -p "$r/etc/kolinos/branding"
    cp "$KOLIN_ROOT_DIR/config/branding/logo.txt" "$r/etc/kolinos/branding/logo.txt"
    {
        echo "NAME=${KOLIN_NAME}"
        echo "VERSION=${KOLIN_VERSION}"
        echo "CODENAME=${KOLIN_CODENAME}"
        echo "DEBIAN_SUITE=${KOLIN_DEBIAN_SUITE}"
        echo "ARCH=${KOLIN_ARCH}"
        echo "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$r/etc/kolinos/version"

    render_template "$KOLIN_ROOT_DIR/config/issue" "$r/etc/issue"
    render_template "$KOLIN_ROOT_DIR/config/issue" "$r/etc/issue.net"

    # --- MOTD: suppress Debian's dynamic snippets, keep ours ---------------
    mkdir -p "$r/etc/update-motd.d"
    chmod -x "$r"/etc/update-motd.d/* 2>/dev/null || true
    for f in "$r"/etc/motd.d/*; do [ -e "$f" ] && echo -n > "$f"; done

    # --- shell profile / prompt ------------------------------------------
    install -d -m 0755 "$r/etc/profile.d"
    render_template "$KOLIN_ROOT_DIR/config/skel/kolinos.sh" "$r/etc/profile.d/kolinos.sh"
    chmod 0644 "$r/etc/profile.d/kolinos.sh"

    install -d -m 0755 "$r/etc/skel" "$r/root"
    for home in "$r/etc/skel" "$r/root"; do
        [ -f "$home/.bashrc" ] || cp "$r/etc/skel/.bashrc" "$home/.bashrc" 2>/dev/null || true
        # Ensure our snippet is sourced exactly once.
        if ! grep -q 'profile.d/kolinos.sh' "$home/.bashrc" 2>/dev/null; then
            printf '\n# KolinOS shell environment\n[ -f /etc/profile.d/kolinos.sh ] && . /etc/profile.d/kolinos.sh\n' >> "$home/.bashrc"
        fi
    done

    # --- locale & timezone are handled by 45-system.sh --------------------
    printf '%s\n' "$KOLIN_TIMEZONE" > "$r/etc/timezone"
    if [ -f "$r/usr/share/zoneinfo/$KOLIN_TIMEZONE" ]; then
        ln -sf "/usr/share/zoneinfo/$KOLIN_TIMEZONE" "$r/etc/localtime"
    fi

    log "identidade aplicada (${KOLIN_NAME} ${KOLIN_VERSION} \"${KOLIN_CODENAME}\")"
}
