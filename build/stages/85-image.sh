#!/usr/bin/env bash
# Stage 85 — build a distributable disk image (FASE 8).
#
# Produces kolinos-<ver>-<codename>-<arch>.img: a GPT disk with a FAT32 EFI
# System Partition (GRUB + kernel + initrd, branded menu) and an ext4 root
# partition carrying the rootfs. The image boots under UEFI, which is what QEMU
# virt and most arm64 boards and VMs provide. It is NOT a phone image: an
# Android device needs its own bootloader and a kernel with the device tree
# (FASE 10) — see docs/LIMITATIONS.md.
#
# The image is assembled WITHOUT loop devices, because a container usually has
# none (/dev/loop* absent, CAP_MKNOD dropped). Instead of mounting:
#   * partition table      : parted on the image file
#   * FAT32 ESP            : mformat/mcopy (mtools) at a byte offset
#   * ext4 root partition  : mke2fs -d <rootfs dir> at a byte offset
#   * UUIDs and fstab      : read back with dumpe2fs / blkid
# A real-root host may instead attach a loop device, but that path is optional.
#
# Opt-in, like the desktop stage: the base image stays lean.
stage_main() {
    local r="$KOLIN_ROOTFS"

    if [ "${KOLIN_IMAGE:-0}" != 1 ]; then
        log "imagem de disco desativada (use --with-image para incluir)"
        return 0
    fi

    [ -f "$r/etc/os-release" ] || die "rootfs ausente; rode os estágios anteriores primeiro"
    require_root

    # A bootable image needs a kernel, an initramfs generator and a bootloader.
    # They are not in the lean base set (they are meaningless in proot), so the
    # image stage pulls them in on demand.
    local boot_pkgs="linux-image-arm64 initramfs-tools"
    [ "${KOLIN_IMAGE_BOOTLOADER:-1}" = 1 ] && boot_pkgs="$boot_pkgs grub-efi-arm64-bin"
    if ! kolin_run "$r" 'dpkg-query -W linux-image-arm64 >/dev/null 2>&1 && test -d /usr/lib/grub/arm64-efi'; then
        log "instalando suporte de boot no rootfs: $boot_pkgs"
        kolin_run "$r" "export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq --no-install-recommends $boot_pkgs" || \
            warn "não foi possível instalar todo o suporte de boot"
    fi

    # The initramfs must be able to mount the root partition it will be handed.
    # ext4 is a built-in module, but the virtio/9p drivers used by VMs are not;
    # without them the initrd cannot find its root on a virtual disk.
    kolin_run "$r" "grep -q '^9pnet_virtio' /etc/initramfs-tools/modules 2>/dev/null || \
        printf 'virtio_pci\nvirtio_blk\nvirtio_scsi\nvirtio_mmio\n9p\n9pnet\n9pnet_virtio\nfscache\n' \
            >> /etc/initramfs-tools/modules"
    kolin_run "$r" 'update-initramfs -u -k all >/dev/null 2>&1 || true'

    local have_all=1 t
    for t in parted mke2fs dumpe2fs mcopy mmd mformat blkid; do
        have "$t" || { warn "ferramenta ausente: $t"; have_all=0; }
    done
    [ "$have_all" = 1 ] || die "instale as ferramentas de imagem (parted e2fsprogs mtools util-linux)"

    # --- the kernel and initrd must be inside the rootfs --------------------
    local kernel initrd
    kernel="$(ls "$r"/boot/vmlinuz-* 2>/dev/null | sort | tail -1)"
    initrd="$(ls "$r"/boot/initrd.img-* 2>/dev/null | sort | tail -1)"
    [ -n "$kernel" ] || die "sem kernel em $r/boot — instale linux-image-arm64 antes da imagem"
    [ -n "$initrd" ] || die "sem initrd em $r/boot — instale initramfs-tools antes da imagem"

    # GRUB EFI is needed for a *bootable* image. Without it we still produce a
    # valid (but not bootable) data image, and say so plainly.
    local bootable=1
    if ! kolin_run "$r" 'test -d /usr/lib/grub/arm64-efi'; then
        warn "GRUB EFI arm64 ausente no rootfs: a imagem será gravável, porém NÃO inicializável"
        warn "para uma imagem inicializável: chroot rootfs apt-get install grub-efi-arm64-bin"
        bootable=0
    fi

    # --- sizes --------------------------------------------------------------
    # The rootfs is ~700 MiB of files; ext4 metadata and the 5% reserved blocks
    # need headroom, so size the partition from the real usage and round up.
    local used_mb root_mb esp_mb disk_mb
    used_mb=$(( $(du -sm "$r" | awk '{print $1}') + 128 ))
    root_mb=$(( used_mb * 115 / 100 ))
    esp_mb=128
    disk_mb=$(( root_mb + esp_mb + 4 ))

    local out="$KOLIN_OUTPUT_DIR"
    mkdir -p "$out"
    local img="$out/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.img"
    rm -f "$img"

    log "criando imagem de ${disk_mb}MiB (rootfs ${used_mb}MiB, ESP ${esp_mb}MiB)"
    truncate -s "${disk_mb}M" "$img"

    # --- partition table ----------------------------------------------------
    # 1 MiB alignment: the ESP starts where a GPT disk conventionally does.
    parted -s "$img" mklabel gpt
    parted -s "$img" mkpart ESP fat32 1MiB "$(( 1 + esp_mb ))MiB"
    parted -s "$img" set 1 esp on
    parted -s "$img" mkpart root ext4 "$(( 1 + esp_mb ))MiB" 100%

    local esp_start=1
    local root_start=$(( 1 + esp_mb ))
    local root_size=$(( disk_mb - root_start - 1 ))

    # --- fstab: the image must mount its own root ---------------------------
    # The shipped fstab is empty on purpose (containers ignore it); a disk image
    # needs real entries or the system will not find its root. This MUST be
    # written before mke2fs -d, which snapshots the tree into the image.
    # The UUID is derived from the name, not random, so rebuilds stay stable.
    local root_uuid
    root_uuid="$(kolin_det_uuid "KOLINOS-ROOT-${KOLIN_VERSION}-${KOLIN_ARCH}")"

    log "escrevendo /etc/fstab para a imagem"
    cat > "$r/etc/fstab" <<EOF
# /etc/fstab — KolinOS (generated by the image build).
# <file system>  <mount point>  <type>  <options>          <dump> <pass>
UUID=$root_uuid  /              ext4    errors=remount-ro  0      1
EOF

    # --- root partition: ext4 populated straight from the rootfs ------------
    # mke2fs -d copies the directory tree into the new filesystem without any
    # mount. -E offset= places it inside the image at the partition boundary.
    # Fixed UUID and label keep the image reproducible.
    log "formatando a partição root (ext4) e copiando o rootfs ..."
    mke2fs -q -t ext4 -F \
        -E "offset=$(( root_start * 1024 * 1024 ))" \
        -L "KOLINOS" -U "$root_uuid" \
        -d "$r" \
        "$img" "${root_size}M" || die "mke2fs falhou ao criar a partição root"

    # --- ESP: GRUB, kernel, initrd ------------------------------------------
    local esp_img="$out/.kolinos-esp.tmp"
    rm -f "$esp_img"
    truncate -s "${esp_mb}M" "$esp_img"
    mformat -i "$esp_img" -F -v KOLINESP -N "$(kolin_det_serial "$img")" ::

    local esp_tree="$out/.kolinos-esp.tree"
    rm -rf "$esp_tree"
    mkdir -p "$esp_tree/EFI/BOOT" "$esp_tree/EFI/kolinos" "$esp_tree/grub"

    if [ "$bootable" = 1 ]; then
        # grub-mkstandalone packs the modules, the font and the config into one
        # self-contained EFI binary, so the ESP needs no separate grub/ tree.
        kolin_make_grub_efi "$r" "$esp_tree/EFI/BOOT/BOOTAA64.EFI" "$root_uuid"
    fi

    cp "$kernel" "$esp_tree/vmlinuz"
    cp "$initrd" "$esp_tree/initrd.img"

    # --- branded GRUB menu ---------------------------------------------------
    kolin_write_grub_cfg "$esp_tree/EFI/kolinos/grub.cfg" "$root_uuid"
    if kolin_grub_background "$esp_tree/EFI/kolinos/background.png"; then
        log "menu GRUB com fundo Corvo Glass"
    fi

    # Copy the ESP tree in with mtools (works on the image file, no loop device).
    ( cd "$esp_tree" && find . -mindepth 1 -type d -printf '%P\n' | sort | while read -r d; do
          mmd -i "$esp_img" "::/$d"
      done )
    ( cd "$esp_tree" && find . -type f -printf '%P\n' | sort | while read -r f; do
          mcopy -i "$esp_img" "$f" "::/$f"
      done )

    # Splice the FAT filesystem into the GPT image at the ESP offset.
    dd if="$esp_img" of="$img" bs=1M seek="$esp_start" conv=notrunc status=none
    rm -f "$esp_img"; rm -rf "$esp_tree"

    # --- label the ESP in the GPT -------------------------------------------
    # blkid/mtools wrote a real FAT filesystem, but the GPT entry needs its own
    # type and a stable PARTUUID for firmware that looks them up.
    local esp_uuid
    esp_uuid="$(kolin_det_uuid "KOLINOS-ESP-${KOLIN_VERSION}-${KOLIN_ARCH}")"
    if have sgdisk; then
        sgdisk -t 1:EF00 -t 2:8300 -u "1:$esp_uuid" -u "2:$root_uuid" "$img" >/dev/null 2>&1 || \
            warn "sgdisk não ajustou os GUIDs (a tabela continua válida)"
    fi

    # --- restore the shipped (empty) fstab ----------------------------------
    # The rootfs tree is reused by other artifacts; do not leave the image's
    # fstab behind or a later tar/ISO would ship it too.
    cat > "$r/etc/fstab" <<'EOF'
# /etc/fstab — KolinOS static filesystem information.
# In containers (Termux/proot) and chroot this file is not consulted.
# <file system>  <mount point>  <type>  <options>  <dump>  <pass>
EOF

    # Deterministic timestamps for the image itself.
    touch -d "@$KOLIN_BUILD_EPOCH" "$img" 2>/dev/null || true

    # Sparse files and zeroed free space compress well; a raw 1.6 GiB image is
    # unusable on a phone, so ship an xz-compressed copy next to it. The raw
    # image stays for direct 'dd' and for QEMU.
    if [ "${KOLIN_IMAGE_COMPRESS:-1}" = 1 ] && have xz; then
        log "comprimindo a imagem (xz) ..."
        xz -T0 -1 -c "$img" > "$img.xz"
        touch -d "@$KOLIN_BUILD_EPOCH" "$img.xz" 2>/dev/null || true
        log "imagem comprimida: $img.xz ($(human_size "$img.xz"))"
    fi

    if [ "$bootable" = 1 ]; then
        log "imagem inicializável (UEFI): $img  ($(human_size "$img"))"
    else
        warn "imagem NÃO inicializável (sem GRUB EFI): $img  ($(human_size "$img"))"
    fi
    log "teste de boot: sudo bash scripts/host/qemu-boot.sh --image $img"
}

# ---------------------------------------------------------------------------
# Helpers (stage-local: prefixed to avoid clashing with build/lib/common.sh)
# ---------------------------------------------------------------------------

# Deterministic UUID derived from a name, so two builds of the same commit
# produce identical partition identifiers (reproducibility, FASE 4).
kolin_det_uuid() {
    local h
    h="$(printf '%s' "$1" | sha256sum | cut -c1-32)"
    printf '%s-%s-4%s-8%s-%s\n' \
        "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

kolin_det_serial() { printf '%s' "$1" | sha256sum | cut -c1-8 | tr 'a-f' 'A-F'; }

# Build the self-contained GRUB EFI binary inside the rootfs (which has the
# arm64-efi modules; the host does not).
kolin_make_grub_efi() {
    local r="$1" out_efi="$2" root_uuid="$3"
    local tmp="/tmp/kolinos-grub-$$"
    kolin_run "$r" "rm -rf $tmp && mkdir -p $tmp/EFI/kolinos"
    # The embedded menu needs the real root UUID, so render it before embedding.
    kolin_write_grub_cfg "$r$tmp/EFI/kolinos/grub.cfg" "$root_uuid"
    # grub-mkstandalone folds the modules, font and menu into one EFI file, so
    # the ESP needs no /boot/grub tree of its own.
    kolin_run "$r" "grub-mkstandalone -O arm64-efi \
        --modules='part_gpt part_msdos fat ext2 normal linux search search_label search_fs_uuid configfile echo test gfxterm gfxmenu png font all_video videoinfo serial terminal' \
        --fonts='unicode' \
        -o $tmp/BOOTAA64.EFI \
        'boot/grub/grub.cfg=$tmp/EFI/kolinos/grub.cfg'" || die "grub-mkstandalone falhou"
    install -D -m 0644 "$r$tmp/BOOTAA64.EFI" "$out_efi"
    kolin_run "$r" "rm -rf $tmp"
}

# Render the GRUB menu from config/boot/grub.cfg.in with the real root UUID.
kolin_write_grub_cfg() {
    local out="$1" root_uuid="$2"
    KOLIN_ROOT_UUID="$root_uuid" \
        render_template "$KOLIN_ROOT_DIR/config/boot/grub.cfg.in" "$out"
}

# Branded menu background. The wallpaper is an SVG with colour tokens; render it
# to PNG (GRUB reads PNG, not SVG). Best-effort: a missing renderer only means a
# plain text menu, never a failed image build.
kolin_grub_background() {
    local out="$1"
    have rsvg-convert || return 1
    local svg="$KOLIN_ROOT_DIR/config/branding/wallpaper-mobile.svg"
    [ -f "$svg" ] || return 1
    local stage="/tmp/kolinos-grub-bg-$$.svg"
    render_template "$svg" "$stage" 2>/dev/null || return 1
    rsvg-convert -w 1024 -h 768 "$stage" -o "$out" 2>/dev/null || { rm -f "$stage"; return 1; }
    rm -f "$stage"
    return 0
}
