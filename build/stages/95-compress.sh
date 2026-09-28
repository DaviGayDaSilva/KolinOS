#!/usr/bin/env bash
# Stage 95 — compress the disk image (FASE 8/10).
#
# Placed deliberately after stage 90: a board profile patches the image (adds
# its device trees to the ESP), and compressing before that would leave a .xz
# whose bytes no longer match the .img next to it — a checksum would verify and
# the two would still differ. Compressing once, at the end, avoids both the
# mismatch and a second multi-minute xz pass over a 1.4 GiB file.
#
# The raw image is kept: it is what QEMU and a direct `dd` use, and what stage
# 90 modifies. The .xz is the distribution artifact, since a raw 1.4 GiB file
# is unusable on a phone.
#
# xz -1 rather than -9 on purpose: decompression time on a phone matters more
# than the last few percent of ratio, and -1 is several times faster.
stage_main() {
    local out="$KOLIN_OUTPUT_DIR"
    local img="$out/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.img"

    if [ ! -f "$img" ]; then
        # No image (no --with-image): nothing to compress, and that is not an
        # error. Do not warn — it would be noise in the common lean build.
        log "sem imagem de disco para comprimir"
        return 0
    fi
    if [ "${KOLIN_IMAGE_COMPRESS:-1}" != 1 ]; then
        log "compressão da imagem desativada (KOLIN_IMAGE_COMPRESS=0)"
        return 0
    fi
    if ! have xz; then
        warn "xz ausente: a imagem fica só sem comprimir ($img)"
        return 0
    fi

    # Skip when the .xz is already newer than the .img: a repeated stage run
    # should not spend minutes redoing identical work.
    if [ -f "$img.xz" ] && [ "$img.xz" -nt "$img" ]; then
        log "imagem já comprimida e atual: $img.xz ($(human_size "$img.xz"))"
        return 0
    fi

    log "comprimindo a imagem (xz -1) ..."
    # Write to a temp name and move into place only on success, so an interrupted
    # run never leaves a truncated .xz that looks complete.
    if xz -T0 -1 -c "$img" > "$img.xz.new"; then
        mv "$img.xz.new" "$img.xz"
        touch -d "@$KOLIN_BUILD_EPOCH" "$img.xz" 2>/dev/null || true
        log "imagem comprimida: $img.xz ($(human_size "$img.xz"))"
    else
        rm -f "$img.xz.new"
        warn "compressão falhou; a imagem crua continua válida em $img"
    fi
}
