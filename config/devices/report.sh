#!/usr/bin/env bash
# report.sh — which device profiles can actually be used on THIS machine.
#
# The point is honesty before effort. Building a boot.img needs mkbootimg; a Pi
# image needs the kernel's bcm2711 device trees; flashing needs a device on USB.
# Rather than let a build fail halfway, this reports per profile what is present
# and what is missing, and separates "not installed" (fixable) from "impossible
# here" (needs another machine or real hardware).
#
# Read-only: it inspects tools, files and the environment; it never installs,
# mounts or writes. Safe to run anywhere, including Termux.
#
# Usage: bash config/devices/report.sh [profile ...]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"

WANT=("$@")
if [ "${#WANT[@]}" -eq 0 ]; then
    # Every profile except self-describing README.md.
    mapfile -t WANT < <(cd "$SELF_DIR" && ls -1 *.conf 2>/dev/null | sed 's/\.conf$//' | sort)
fi
[ "${#WANT[@]}" -gt 0 ] || { echo "nenhum perfil em $SELF_DIR" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Environment facts, computed once.
KERNEL_MATCH=""
if [ -d "/usr/lib/linux-image-${KOLIN_KERNEL_VERSION:-}" ]; then
    KERNEL_MATCH="/usr/lib/linux-image-${KOLIN_KERNEL_VERSION}"
fi
IS_ROOT=0
[ "$(id -u)" = 0 ] && IS_ROOT=1
IS_TERMUX=0
[ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ] && IS_TERMUX=1
IS_ANDROID=0
[ -f /system/build.prop ] && IS_ANDROID=1

mark() {  # mark <ok|miss|no> <text>
    case "$1" in
        ok)   printf '    [ok]    %s\n' "$2" ;;
        miss) printf '    [falta] %s\n' "$2" ;;
        no)   printf '    [n/a]   %s\n' "$2" ;;
    esac
}

for id in "${WANT[@]}"; do
    conf="$SELF_DIR/$id.conf"
    if [ ! -f "$conf" ]; then
        printf 'perfil desconhecido: %s\n' "$id" >&2
        exit 2
    fi
    # Fresh variables per profile: a previous profile's DTB list must not leak.
    KOLIN_DEVICE_ID=""; KOLIN_DEVICE_LABEL=""; KOLIN_DEVICE_KIND=""
    KOLIN_DEVICE_KERNEL=""; KOLIN_DEVICE_DTB_DIR=""; KOLIN_DEVICE_DTB=""
    KOLIN_DEVICE_BOOTIMG=0; KOLIN_DEVICE_NOTES=""; KOLIN_DEVICE_EXTRA_PKGS=""
    # shellcheck disable=SC1090
    source "$conf"

    printf '\n%s%s%s  (%s)\n' "$KOLIN_DEVICE_ID" " — " "$KOLIN_DEVICE_LABEL" "$KOLIN_DEVICE_KIND"
    printf '  kind: %s\n' "$KOLIN_DEVICE_KIND"

    case "$KOLIN_DEVICE_KIND" in
        uefi)
            if have grub-mkstandalone || have grub-install; then
                mark ok "GRUB disponível no host"
            else
                mark miss "GRUB ausente (pacote grub-efi-arm64-bin no host)"
            fi
            have mkfs.vfat && mark ok "mkfs.vfat disponível" || mark miss "dosfstools ausente"
            have mformat && mark ok "mtools disponível" || mark miss "mtools ausente (leitura/escrita de FAT)"
            [ -e /dev/kvm ] && mark ok "KVM presente: QEMU roda rápido" \
                || mark ok "sem KVM: QEMU roda, porém lento (esperado em container/Termux)"
            mark ok "perfil padrão: o build gera esta imagem sem --device"
            ;;
        sbc)
            have mkfs.vfat && mark ok "mkfs.vfat disponível" || mark miss "dosfstools ausente"
            have dtc && mark ok "dtc disponível" || mark miss "device-tree-compiler ausente (conferir DTB)"
            if [ "$id" = "rpi4" ]; then
                mark no "firmware VideoCore/EEPROM: só existe no Pi, não no host"
                if compgen -G "/usr/lib/linux-image-*/$KOLIN_DEVICE_DTB_DIR/bcm2711-rpi-4-b.dtb" >/dev/null 2>&1; then
                    mark ok "dtb bcm2711 presente no host (kernel instalado aqui)"
                else
                    mark miss "dtb bcm2711 ausente no host: o estágio extrai do .deb do kernel"
                fi
            fi
            ;;
        android)
            have mkbootimg && mark ok "mkbootimg disponível ($(command -v mkbootimg))" \
                || mark miss "mkbootimg ausente (apt install mkbootimg)"
            have fastboot && mark ok "fastboot disponível" \
                || mark miss "fastboot ausente (apt install fastboot; no Termux: android-tools)"
            if have kolinos-bootimg; then
                mark ok "kolinos-bootimg disponível (validação)"
            elif [ -x "$ROOT/build/native-host/kolinos-bootimg" ]; then
                mark ok "kolinos-bootimg compilado em build/native-host/"
            else
                mark miss "kolinos-bootimg não compilado (make) — só validação"
            fi
            have dtc && mark ok "dtc disponível" || mark miss "device-tree-compiler ausente"
            [ "$IS_ROOT" = 1 ] && mark ok "executando como root (initramfs e mknod funcionam)" \
                || mark no "sem root: initramfs com /dev real e mkbootimg em alguns hosts exigem root"
            [ -d /dev/bus/usb ] && mark ok "/dev/bus/usb presente (fastboot pode enxergar o aparelho)" \
                || mark no "/dev/bus/usb ausente: fastboot não vê aparelho dentro deste container"
            mark no "flashing real exige bootloader desbloqueado e o aparelho na USB"
            ;;
    esac

    if [ -n "${KOLIN_DEVICE_NOTES:-}" ]; then
        printf '  aviso: %s\n' "$KOLIN_DEVICE_NOTES"
    fi
done

printf '\nambiente: root=%d termux=%d android=%d arch=%s\n' \
    "$IS_ROOT" "$IS_TERMUX" "$IS_ANDROID" "$(uname -m)"
printf 'este relatório não instala nem grava nada; é apenas diagnóstico.\n'
