#!/usr/bin/env bash
# Stage 70 — clean the rootfs and pack it into a distributable archive.
stage_main() {
    local r="$KOLIN_ROOTFS"
    [ -f "$r/etc/os-release" ] || die "rootfs ausente; rode os estágios anteriores primeiro"

    log "limpando o rootfs ..."
    kolin_run "$r" '
        export DEBIAN_FRONTEND=noninteractive
        apt-get clean
        rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/* 2>/dev/null || true
        rm -f /var/lib/dbus/machine-id 2>/dev/null || true
        : > /etc/machine-id 2>/dev/null || true
        rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
    ' || warn "algumas limpezas falharam (não fatal)"

    if [ "$KOLIN_KEEP_QEMU" != 1 ]; then
        kolin_remove_qemu "$r"
    fi

    mkdir -p "$KOLIN_OUTPUT_DIR"
    local tarball="$KOLIN_OUTPUT_DIR/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.tar.xz"

    log "empacotando $tarball ..."
    # --numeric-owner keeps uid/gid; --xattrs keeps security capabilities.
    tar -C "$r" --numeric-owner --xattrs --xattrs-include='*' \
        -cJf "$tarball" . 2>/dev/null || \
    tar -C "$r" --numeric-owner -cJf "$tarball" .

    log "rootfs: $(human_size "$r")  →  $(human_size "$tarball")"
}
