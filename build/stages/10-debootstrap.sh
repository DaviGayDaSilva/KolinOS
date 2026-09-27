#!/usr/bin/env bash
# Stage 10 — create the base Debian rootfs with debootstrap.
stage_main() {
    local r="$KOLIN_ROOTFS"

    if [ -f "$r/etc/os-release" ] && [ "$KOLIN_FORCE" != 1 ]; then
        log "rootfs já existe em $r — pulando debootstrap (use --force para recriar)"
        return 0
    fi

    if [ "$KOLIN_FORCE" = 1 ] && [ -d "$r" ]; then
        log "--force: removendo rootfs antigo"
        # Never rm -rf the project root by accident.
        [ "$r" != "/" ] && [ "$r" != "$HOME" ] || die "recusando remover $r"
        rm -rf "$r"
    fi

    mkdir -p "$r"
    local opts=(--variant=minbase --arch="$DEB_ARCH")
    local foreign=0
    if [ "$(uname -m)" != "aarch64" ] && [ "$DEB_ARCH" = "arm64" ]; then
        opts+=(--foreign); foreign=1
    fi

    log "debootstrap ${DEB_ARCH}/${KOLIN_DEBIAN_SUITE} em $r ..."
    debootstrap "${opts[@]}" "$KOLIN_DEBIAN_SUITE" "$r" "$KOLIN_DEBIAN_MIRROR"

    if [ "$foreign" = 1 ]; then
        log "segundo estágio via QEMU (cross-arch)"
        kolin_ensure_qemu "$r"
        kolin_mount_pseudo "$r"
        chroot "$r" /debootstrap/debootstrap --second-stage
        kolin_umount_pseudo "$r"
    fi

    log "rootfs base criado ($(human_size "$r"))"
}
