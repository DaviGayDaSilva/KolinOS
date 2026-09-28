#!/usr/bin/env bash
# Stage 90 — device-specific artifacts (FASE 10).
#
# Stage 85 builds one generic UEFI disk image. This stage takes the same rootfs
# and produces what a *named* device needs, driven entirely by the profile in
# config/devices/<id>.conf:
#
#   uefi   : nothing beyond stage 85's image; the profile only documents intent.
#   sbc    : the UEFI image, plus the board's device trees copied onto the ESP
#            and a GRUB entry that passes `devicetree` — how a Pi 4 boots a
#            mainline/ Debian kernel under UEFI.
#   android: an Android boot.img (header v2), validated with kolinos-bootimg.
#
# Everything here is best-effort by design. Real-hardware support spans work that
# simply cannot happen inside a container: flashing needs USB and an unlocked
# bootloader, a Pi needs EEPROM firmware, a phone needs a kernel built for its
# SoC. The stage therefore produces and *verifies* the artifact it can, and
# prints exactly which later step needs real hardware. A missing tool skips that
# artifact with a warning instead of failing an otherwise-good build.
stage_main() {
    local r="$KOLIN_ROOTFS"

    if [ -z "${KOLIN_DEVICE:-}" ]; then
        log "nenhum perfil de dispositivo (--device); nada específico de hardware"
        return 0
    fi

    local conf="$KOLIN_DEVICES_DIR/$KOLIN_DEVICE.conf"
    [ -f "$conf" ] || die "perfil de dispositivo ausente: $conf"

    # Defaults first: sourcing a profile must never inherit a value from a
    # previous profile or from the environment.
    KOLIN_DEVICE_ID="$KOLIN_DEVICE"
    KOLIN_DEVICE_LABEL=""; KOLIN_DEVICE_KIND=""
    KOLIN_DEVICE_BOOTLOADER=""; KOLIN_DEVICE_KERNEL=""
    KOLIN_DEVICE_KERNEL_FLAVOR=""; KOLIN_DEVICE_DTB_DIR=""; KOLIN_DEVICE_DTB=""
    KOLIN_DEVICE_CMDLINE=""; KOLIN_DEVICE_INITRD_MODULES=""
    KOLIN_DEVICE_EXTRA_PKGS=""; KOLIN_DEVICE_BOOTIMG=0; KOLIN_DEVICE_NOTES=""
    # shellcheck disable=SC1090
    source "$conf"

    log "perfil de dispositivo: $KOLIN_DEVICE_ID — $KOLIN_DEVICE_LABEL ($KOLIN_DEVICE_KIND)"
    [ -n "$KOLIN_DEVICE_NOTES" ] && warn "$KOLIN_DEVICE_NOTES"

    [ -f "$r/etc/os-release" ] || die "rootfs ausente; rode os estágios anteriores primeiro"

    local out="$KOLIN_OUTPUT_DIR"
    local tag="${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}-${KOLIN_DEVICE_ID}"
    mkdir -p "$out"

    # Extra packages the profile needs inside the target (e.g. mkbootimg is a
    # build tool, not a target package; but a board's wifi firmware would be).
    if [ -n "$KOLIN_DEVICE_EXTRA_PKGS" ]; then
        log "instalando pacotes do perfil: $KOLIN_DEVICE_EXTRA_PKGS"
        kolin_run "$r" "export DEBIAN_FRONTEND=noninteractive; \
            apt-get install -y -qq --no-install-recommends $KOLIN_DEVICE_EXTRA_PKGS" \
            || warn "não foi possível instalar: $KOLIN_DEVICE_EXTRA_PKGS"
    fi

    case "$KOLIN_DEVICE_KIND" in
        uefi)    stage90_uefi "$r" "$out" "$tag" ;;
        sbc)     stage90_sbc  "$r" "$out" "$tag" ;;
        android) stage90_android "$r" "$out" "$tag" ;;
        *)       die "kind desconhecido no perfil: $KOLIN_DEVICE_KIND" ;;
    esac
}

# --------------------------------------------------------------------------
# uefi: the generic image is already the artifact. Record which profile it was
# built for so the output directory is self-describing.
# --------------------------------------------------------------------------
stage90_uefi() {
    local r="$1" out="$2" tag="$3"
    local img="$out/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.img"
    if [ ! -f "$img" ]; then
        warn "imagem UEFI ausente (${img##*/}); rode com --with-image"
        return 0
    fi
    stage90_write_build_info "$out" "$tag" "$img"
    log "artefato UEFI: $img"
}

# --------------------------------------------------------------------------
# sbc: add the board device trees to the ESP of the generic image and a GRUB
# entry that selects one. The image is rebuilt in place — the ESP is a FAT
# filesystem with room, and re-running mke2fs for the root partition would only
# slow the build for no benefit.
# --------------------------------------------------------------------------
stage90_sbc() {
    local r="$1" out="$2" tag="$3"
    local img="$out/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.img"

    # The kernel package drops its device trees under a versioned directory.
    # Resolve by glob, never by a hardcoded version string.
    local dtb_root
    dtb_root="$(ls -d "$r"/usr/lib/linux-image-*/ 2>/dev/null | sort | tail -1)"
    if [ -z "$dtb_root" ] || [ ! -d "$dtb_root" ]; then
        warn "sem device trees no rootfs ($r/usr/lib/linux-image-*); o Pi não inicia"
        warn "instale linux-image-arm64 no rootfs antes de --device $KOLIN_DEVICE_ID"
        return 0
    fi

    local dtb_dir="$dtb_root${KOLIN_DEVICE_DTB_DIR:+$KOLIN_DEVICE_DTB_DIR/}"
    local copied=0 d src
    local dtb_out="$out/kolinos-${tag}-dtb"
    rm -rf "$dtb_out"; mkdir -p "$dtb_out"

    for d in $KOLIN_DEVICE_DTB; do
        src="$dtb_dir$d"
        if [ -f "$src" ]; then
            cp "$src" "$dtb_out/$d"
            copied=$((copied + 1))
        else
            warn "device tree ausente: $src"
        fi
    done
    [ "$copied" -gt 0 ] || { warn "nenhuma device tree copiada; o perfil $KOLIN_DEVICE_ID não inicializa"; return 0; }

    # Validate the device trees really are flattened device trees, not files
    # with the right name. dtc prints the header; a wrong magic would slip
    # through a plain `cp`.
    if have dtc; then
        for d in "$dtb_out"/*.dtb; do
            if dtc -I dtb -O dts "$d" -o /dev/null 2>/dev/null; then
                log "  $(basename "$d"): device tree válida ($(stat -c%s "$d") bytes)"
            else
                warn "  $(basename "$d"): dtc não reconhece como device tree"
            fi
        done
    else
        warn "dtc ausente: não foi possível validar as device trees (apt install device-tree-compiler)"
    fi

    # Splice the dtbs into the ESP of the existing image. mtools writes into a
    # FAT filesystem inside a file, which is what makes this possible without
    # loop devices or root.
    if [ -f "$img" ] && have mcopy; then
        # Offsets come from the layout stage 85 recorded, not from constants
        # duplicated here: if the ESP grows, this keeps working.
        local layout="$out/.kolinos-image-layout"
        local esp_start_mb=1 esp_mb=128 root_uuid=""
        if [ -f "$layout" ]; then
            # shellcheck disable=SC1090
            . "$layout"
            esp_start_mb="${KOLIN_IMG_ESP_START_MB:-$esp_start_mb}"
            esp_mb="${KOLIN_IMG_ESP_MB:-$esp_mb}"
            root_uuid="${KOLIN_IMG_ROOT_UUID:-}"
        else
            warn "layout da imagem ausente ($layout); usando valores padrão"
        fi
        local esp_img="$out/.kolinos-esp-sbc.tmp"
        rm -f "$esp_img"
        # Read the ESP out, modify it, write it back.
        dd if="$img" of="$esp_img" bs=1M skip="$esp_start_mb" count="$esp_mb" status=none
        mmd -i "$esp_img" "::/dtbs" 2>/dev/null || true
        for d in "$dtb_out"/*.dtb; do
            mcopy -i "$esp_img" -o "$d" "::/dtbs/$(basename "$d")"
        done
        stage90_grub_dtb_menu "$esp_img" "$dtb_out" "$root_uuid" || true
        dd if="$esp_img" of="$img" bs=1M seek="$esp_start_mb" conv=notrunc status=none
        rm -f "$esp_img"
        log "device trees adicionadas à ESP de $img"
    else
        warn "imagem ausente ou mtools indisponível: device trees ficaram só em $dtb_out"
        warn "para incluí-las na imagem: rode com --with-image e mtools instalado"
    fi

    stage90_write_build_info "$out" "$tag" "$img"
}

# Add a GRUB menu entry that boots with a device tree. GRUB's `devicetree`
# command loads a DTB and hands it to the kernel — required on a Pi, where the
# firmware UEFI does not pass one. The original entries stay: this is additive.
#
# The standalone GRUB EFI binary embeds its menu, so this file is not what the
# EFI binary reads. It is shipped for two reasons: it documents the exact
# devicetree wiring, and U-Boot / a chainloaded GRUB with an external grub.cfg
# does read it. The cmdline's @KOLIN_ROOT_UUID@ is rendered here with the real
# UUID, so the file is directly usable rather than a template.
stage90_grub_dtb_menu() {
    local esp_img="$1" dtb_out="$2" root_uuid="$3"
    # Pick the first dtb as the default entry; a user with a Pi 400 edits this.
    local first
    first="$(ls "$dtb_out"/*.dtb 2>/dev/null | sort | head -1)"
    [ -n "$first" ] || return 1
    local name
    name="dtbs/$(basename "$first")"
    if [ -z "$root_uuid" ]; then
        warn "UUID da raiz desconhecido: grub-dtb.cfg sai com @KOLIN_ROOT_UUID@ literal"
    fi

    local menu="$dtb_out/.grub-dtb.cfg"
    KOLIN_ROOT_UUID="$root_uuid" render_template \
        "$KOLIN_ROOT_DIR/config/boot/grub-dtb.cfg.in" "$menu" || return 1
    # Profile-specific values are not in VERSION, so they are substituted here.
    # The profile's cmdline itself contains @KOLIN_ROOT_UUID@, so a second pass
    # replaces it after the cmdline is in place — the template's own occurrence
    # was already handled by render_template.
    sed -i "s|@KOLIN_DTB_PATH@|/$name|g; \
            s|@KOLIN_DEVICE_LABEL@|$KOLIN_DEVICE_LABEL|g; \
            s|@KOLIN_DEVICE_ID@|$KOLIN_DEVICE_ID|g; \
            s|@KOLIN_DEVICE_CMDLINE@|$KOLIN_DEVICE_CMDLINE|g; \
            s|@KOLIN_ROOT_UUID@|$root_uuid|g" "$menu"

    mcopy -i "$esp_img" -o "$menu" "::/EFI/kolinos/grub-dtb.cfg" 2>/dev/null || return 1
    rm -f "$menu"
    return 0
}

# --------------------------------------------------------------------------
# android: build an Android boot image.
#
# The real boot.img format has a 1-page header with magic "ANDROID!", then the
# kernel, ramdisk and (for v2) the dtb, each aligned to the page size. mkbootimg
# from Debian does this properly, so the build calls it rather than hand-rolling
# the header. The result is validated with our own tool, which reads the header
# independently — so a broken image is caught here, not on a phone.
# --------------------------------------------------------------------------
stage90_android() {
    local r="$1" out="$2" tag="$3"
    local img="$out/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.img"
    local boot="$out/kolinos-${tag}-boot.img"

    if ! have mkbootimg; then
        warn "mkbootimg ausente; não é possível gerar boot.img"
        warn "instale no host: apt-get install mkbootimg"
        return 0
    fi

    # Kernel and initrd come from the rootfs, exactly like stage 85 uses them.
    local kernel initrd
    kernel="$(ls "$r"/boot/vmlinuz-* 2>/dev/null | sort | tail -1)"
    initrd="$(ls "$r"/boot/initrd.img-* 2>/dev/null | sort | tail -1)"
    [ -n "$kernel" ] || { warn "sem kernel em $r/boot; instale linux-image-arm64"; return 0; }
    [ -n "$initrd" ] || { warn "sem initrd em $r/boot; instale initramfs-tools"; return 0; }

    # header v2 REQUIRES a non-empty dtb. A phone needs its own model's DTB; the
    # profile may name one from the kernel package, otherwise we generate a
    # minimal valid empty tree so the format is exercisable and the file is a
    # genuine v2 image rather than a malformed one.
    local dtb="$out/.kolinos-boot-dtb.tmp"
    rm -f "$dtb"
    if [ -n "$KOLIN_DEVICE_DTB" ] && have dtc; then
        local dtb_root dtb_dir
        dtb_root="$(ls -d "$r"/usr/lib/linux-image-*/ 2>/dev/null | sort | tail -1)"
        dtb_dir="$dtb_root${KOLIN_DEVICE_DTB_DIR:+$KOLIN_DEVICE_DTB_DIR/}"
        # shellcheck disable=SC2086
        set -- $KOLIN_DEVICE_DTB
        if [ -f "$dtb_dir$1" ]; then
            cp "$dtb_dir$1" "$dtb"
            log "device tree do perfil: $1"
        fi
    fi
    if [ ! -f "$dtb" ]; then
        if have dtc; then
            printf '/dts-v1/;\n/ { model = "KolinOS %s placeholder"; compatible = "kolinos,%s"; };\n' \
                "$KOLIN_VERSION" "$KOLIN_DEVICE_ID" > "$out/.kolinos-boot-dtb.dts"
            dtc -I dts -O dtb -o "$dtb" "$out/.kolinos-boot-dtb.dts" 2>/dev/null \
                && warn "dtb vazia gerada: o boot.img é válido, mas não descreve um aparelho real"
            rm -f "$out/.kolinos-boot-dtb.dts"
        fi
    fi
    [ -f "$dtb" ] || { warn "sem dtb; o header v2 exige uma, então mkbootimg seria recusado"; return 0; }

    # Addresses and offsets are the values a typical arm64 Android bootloader
    # expects; each device differs, so they are parameters a profile can grow
    # into. --pagesize 4096 is universal on modern arm64.
    log "gerando boot.img (header v2, arm64) ..."
    mkbootimg \
        --kernel "$kernel" \
        --ramdisk "$initrd" \
        --dtb "$dtb" \
        --header_version 2 \
        --pagesize 4096 \
        --base 0x10000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x01000000 \
        --tags_offset 0x00000100 \
        --dtb_offset 0x01f00000 \
        --cmdline "$KOLIN_DEVICE_CMDLINE" \
        -o "$boot" || { warn "mkbootimg falhou"; rm -f "$dtb"; return 0; }
    rm -f "$dtb"

    # Validate with our own reader: an independent parse of the header catches
    # a malformed image before it reaches fastboot.
    local validator=""
    if have kolinos-bootimg; then
        validator="kolinos-bootimg"
    elif [ -x "$KOLIN_ROOT_DIR/build/native-host/kolinos-bootimg" ]; then
        validator="$KOLIN_ROOT_DIR/build/native-host/kolinos-bootimg"
    elif [ -x "$KOLIN_ROOT_DIR/build/native/kolinos-bootimg" ]; then
        validator="$KOLIN_ROOT_DIR/build/native/kolinos-bootimg"
    fi

    if [ -n "$validator" ]; then
        if "$validator" verify "$boot"; then
            log "boot.img validado por kolinos-bootimg"
        else
            warn "kolinos-bootimg reportou problemas no boot.img gerado"
        fi
        # Ship the readable report next to the artifact; a phone user has no
        # easy way to run the tool themselves before flashing.
        "$validator" info "$boot" > "$out/kolinos-${tag}-boot.info.txt" 2>&1 || true
    else
        warn "kolinos-bootimg não compilado (make); boot.img gerado sem validação"
    fi

    touch -d "@$KOLIN_BUILD_EPOCH" "$boot" 2>/dev/null || true
    log "artefato Android: $boot ($(human_size "$boot"))"
    warn "gravar exige bootloader DESBLOQUEADO e o aparelho conectado por USB:"
    warn "  fastboot flash boot ${boot##*/}"
    warn "quase nunca inicializa com o kernel Debian genérico; ver docs/PHASE10.md"

    [ -f "$img" ] && stage90_write_build_info "$out" "$tag" "$img"
}

# A per-device note describing what was produced and what remains a manual step.
stage90_write_build_info() {
    local out="$1" tag="$2" img="$3"
    local info="$out/kolinos-${tag}-BUILD.txt"
    {
        printf 'KolinOS %s (%s) — artefatos para %s\n' \
            "$KOLIN_VERSION" "$KOLIN_CODENAME" "$KOLIN_DEVICE_ID"
        printf 'perfil   : %s\n' "$KOLIN_DEVICE_LABEL"
        printf 'kind     : %s\n' "$KOLIN_DEVICE_KIND"
        printf 'boot     : %s\n' "$KOLIN_DEVICE_BOOTLOADER"
        printf 'cmdline  : %s\n' "$KOLIN_DEVICE_CMDLINE"
        printf 'gerado em: %s\n' "$(kolin_iso_utc "$KOLIN_BUILD_EPOCH")"
        printf '\nartefatos:\n'
        for f in "$out"/kolinos-${tag}*; do
            [ -f "$f" ] || continue
            printf '  %s (%s)\n' "$(basename "$f")" "$(human_size "$f")"
        done
        printf '\npróximos passos (exigem hardware real, não o container):\n'
        case "$KOLIN_DEVICE_KIND" in
            uefi)
                printf '  * gravar a imagem em um disco/USB e iniciar por UEFI arm64\n'
                printf '  * testar em QEMU: sudo bash scripts/host/qemu-boot.sh --image %s\n' "$img"
                ;;
            sbc)
                printf '  * atualizar o EEPROM do Pi para UEFI (rpi-eeprom-update) ou usar U-Boot\n'
                printf '  * gravar a imagem no cartão/USB: sudo dd if=%s of=/dev/sdX bs=4M\n' "$img"
                ;;
            android)
                printf '  * desbloquear o bootloader: fastboot flashing unlock\n'
                printf '  * gravar o kernel: fastboot flash boot kolinos-%s-boot.img\n' "$tag"
                printf '  * o boot com kernel genérico quase certamente falha; ver docs/PHASE10.md\n'
                ;;
        esac
    } > "$info"
    log "notas do build: $info"
}
