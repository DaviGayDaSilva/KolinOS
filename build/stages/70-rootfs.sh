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
        rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true
        find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
    ' || warn "algumas limpezas falharam (não fatal)"

    # glibc's aux-cache records inode numbers, which differ on every build.
    # It is only a hint file (the real cache is /etc/ld.so.cache) and is rebuilt
    # on demand, so dropping it keeps the rootfs reproducible.
    rm -f "$r/var/cache/ldconfig/aux-cache"

    # Never ship the build host's resolver configuration.
    cat > "$r/etc/resolv.conf" <<'EOF'
# KolinOS: /etc/resolv.conf is managed at runtime.
EOF
    chmod 0644 "$r/etc/resolv.conf"

    if [ "$KOLIN_KEEP_QEMU" != 1 ]; then
        kolin_remove_qemu "$r"
    fi

    # Reproducibility: one fixed timestamp for every file, so the archive does
    # not embed the build clock. Runs after all cleanup, before tar.
    log "normalizando timestamps para $KOLIN_BUILD_EPOCH ..."
    kolin_stamp_tree "$r" "$KOLIN_BUILD_EPOCH"

    mkdir -p "$KOLIN_OUTPUT_DIR"
    local tarball="$KOLIN_OUTPUT_DIR/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.tar.xz"

    # Reproducibility: stable entry order (LC_ALL=C), fixed mtime, no owner names
    # (root:root is implied by uid/gid 0). --xattrs keeps security capabilities.
    # pax format with atime/ctime deleted: otherwise tar records the read time,
    # which changes on every run.
    log "empacotando $tarball ..."
    (
        cd "$r" || exit 1
        find . -mindepth 1 -print0 \
            | LC_ALL=C sort -z \
            | tar --null --files-from=- --format=pax \
                  --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
                  --owner=0 --group=0 --numeric-owner \
                  --mtime="@$KOLIN_BUILD_EPOCH" \
                  --xattrs --xattrs-include='*' \
                  -cJf "$tarball"
    ) || die "falha ao empacotar o rootfs"

    log "rootfs: $(human_size "$r")  →  $(human_size "$tarball")"
}
