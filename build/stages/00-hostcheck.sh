#!/usr/bin/env bash
# Stage 00 — host sanity checks. Does NOT touch the rootfs.
stage_main() {
    local missing=0
    for t in debootstrap chroot tar; do
        if ! have "$t"; then warn "ferramenta ausente no host: $t"; missing=1; fi
    done
    if [ "$(uname -m)" != "aarch64" ] && [ "$DEB_ARCH" = "arm64" ]; then
        if ! have qemu-aarch64-static; then
            warn "build cross-arch: instale qemu-user-static no host"
            missing=1
        fi
        if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
            warn "binfmt qemu-aarch64 não registrado; o stage de debootstrap vai copiar o qemu manualmente (ok)"
        fi
    fi
    [ "$missing" -eq 0 ] || die "dependências do host incompletas (Debian: apt install debootstrap qemu-user-static)"
    log "host OK para construir ${DEB_ARCH}"
}
