#!/usr/bin/env bash
# qemu-boot.sh — boot a KolinOS artifact under QEMU (aarch64, EDK2 firmware).
#
# This is a *verification* tool, not part of the shipped system: it exists to
# prove that a rootfs or disk image actually reaches userspace, which no amount
# of file inspection can show.
#
# Two modes:
#   --rootfs DIR   boot the rootfs directory directly over virtio-9p. No disk
#                  image is needed, so this works on hosts where /dev/loop* is
#                  unavailable (the usual container situation). The kernel and
#                  initrd come from DIR/boot.
#   --image FILE   boot a disk image produced by build/stages/85-image.sh. This
#                  exercises the real firmware -> systemd-boot -> kernel chain.
#
# QEMU is used without KVM (TCG emulation), so booting an ARM64 system on an
# x86_64 host is slow — expect a few minutes. The script waits for a marker on
# the serial console instead of a fixed timeout, and exits non-zero when the
# system does not reach userspace.
#
# Usage:
#   bash scripts/host/qemu-boot.sh --rootfs ./rootfs [options]
#   bash scripts/host/qemu-boot.sh --image ./output/kolinos-*.img [options]
#
# Options:
#   --rootfs DIR      Rootfs directory to boot over 9p
#   --image FILE      Disk image to boot
#   --ram MB          Guest RAM in MiB (default: 2048)
#   --cpus N          Guest CPUs (default: 2)
#   --timeout SEC     Give up after SEC seconds (default: 420)
#   --expect REGEX    Wait for this regex on the serial console
#                     (default: 'login:|Reached target')
#   --log FILE        Where to tee the serial output (default: output/qemu-boot.log)
#   --extra ARGS      Extra QEMU arguments (single string)
#   -h, --help        Show this help
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_SELF_DIR/../.." && pwd)"
# shellcheck source=../../build/lib/common.sh
. "$ROOT_DIR/build/lib/common.sh"

MODE=""
TARGET=""
RAM=2048
CPUS=2
TIMEOUT=420
EXPECT='login:|Reached target'
LOG="$ROOT_DIR/output/qemu-boot.log"
EXTRA=""

usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs)  MODE=rootfs; TARGET="$2"; shift 2 ;;
        --image)   MODE=image;  TARGET="$2"; shift 2 ;;
        --ram)     RAM="$2"; shift 2 ;;
        --cpus)    CPUS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --expect)  EXPECT="$2"; shift 2 ;;
        --log)     LOG="$2"; shift 2 ;;
        --extra)   EXTRA="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "opção desconhecida: $1 (veja --help)" ;;
    esac
done

[ -n "$MODE" ] || die "escolha --rootfs DIR ou --image FILE"
have qemu-system-aarch64 || die "qemu-system-aarch64 ausente (apt install qemu-system-arm)"

# EDK2 (AAVMF) firmware: QEMU's -bios loads code and vars from one file, so the
# variable store is copied first — otherwise QEMU would write to the read-only
# system copy and UEFI boot entries could not be persisted.
FW_CODE=""
for c in /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
         /usr/share/edk2/aarch64/QEMU_EFI.fd; do
    [ -f "$c" ] && { FW_CODE="$c"; break; }
done
[ -n "$FW_CODE" ] || die "firmware UEFI aarch64 ausente (apt install qemu-efi-aarch64)"

FW_VARS=""
for v in /usr/share/AAVMF/AAVMF_VARS.fd /usr/share/qemu-efi-aarch64/QEMU_VARS.fd; do
    [ -f "$v" ] && { FW_VARS="$v"; break; }
done

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-qemu.XXXXXX")"
# Without this, every run leaks the firmware vars copy and (in image mode) a
# full copy of the disk image — 1.4 GiB each time.
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT INT TERM
FW_COPY="$RUN_DIR/vars.fd"
if [ -n "$FW_VARS" ]; then
    cp "$FW_VARS" "$FW_COPY"
else
    # No template available: let QEMU create a writable copy of the code file.
    FW_COPY="$RUN_DIR/code.fd"
    cp "$FW_CODE" "$FW_COPY"
fi

QEMU_ARGS=(
    -machine virt
    -cpu cortex-a72
    -smp "$CPUS"
    -m "$RAM"
    -nographic
    -no-reboot
)
if [ -n "$FW_VARS" ]; then
    QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=$FW_CODE")
    QEMU_ARGS+=(-drive "if=pflash,format=raw,file=$FW_COPY")
else
    QEMU_ARGS+=(-bios "$FW_COPY")
fi

case "$MODE" in
    rootfs)
        [ -d "$TARGET" ] || die "rootfs não encontrado: $TARGET"
        TARGET="$(cd "$TARGET" && pwd)"
        KERNEL="$(ls "$TARGET"/boot/vmlinuz-* 2>/dev/null | sort | tail -1)"
        INITRD="$(ls "$TARGET"/boot/initrd.img-* 2>/dev/null | sort | tail -1)"
        [ -n "$KERNEL" ] || die "sem kernel em $TARGET/boot (instale linux-image-arm64)"
        [ -n "$INITRD" ] || die "sem initrd em $TARGET/boot (instale initramfs-tools)"
        # 9p shares the host directory with the guest; the initramfs mounts it as
        # root, so this path never writes to a disk image.
        QEMU_ARGS+=(
            -kernel "$KERNEL"
            -initrd "$INITRD"
            -append "root=9p rootfstype=9p rootflags=trans=virtio,version=9p2000.L,msize=104857600 rw console=ttyAMA0 loglevel=7"
            -fsdev "local,id=fsdev0,path=$TARGET,security_model=none"
            -device "virtio-9p-pci,fsdev=fsdev0,mount_tag=9p"
        )
        ;;
    image)
        [ -f "$TARGET" ] || die "imagem não encontrada: $TARGET"
        TARGET="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
        # Boot a private copy: systemd writes to the journal on first boot, so
        # booting the shipped image in place would mutate the artifact and break
        # its checksum. Copying keeps the file under output/ pristine.
        BOOT_IMG="$RUN_DIR/disk.img"
        log "copiando a imagem para $BOOT_IMG (o original não é alterado)"
        cp --reflink=auto "$TARGET" "$BOOT_IMG" 2>/dev/null || cp "$TARGET" "$BOOT_IMG"
        QEMU_ARGS+=(
            -drive "if=none,format=raw,file=$BOOT_IMG,id=hd0"
            -device "virtio-blk-pci,drive=hd0,bootindex=0"
            -device "virtio-net-pci,netdev=n0"
            -netdev "user,id=n0"
        )
        ;;
esac

[ -n "$EXTRA" ] && read -r -a _extra <<< "$EXTRA" && QEMU_ARGS+=("${_extra[@]}")

mkdir -p "$(dirname "$LOG")"
log "boot QEMU ($MODE): $TARGET"
log "firmware: $FW_CODE"
log "log serial: $LOG  (timeout ${TIMEOUT}s)"

: > "$LOG"
set +e
# Launch qemu directly (no pipe): `$!` must be the process that owns qemu, or
# the kill below would only reach a `tee` and leave qemu running until the
# timeout, holding the disk image open. `timeout` is the parent of qemu, so
# killing it and its children stops the VM for real.
timeout --foreground "$TIMEOUT" qemu-system-aarch64 "${QEMU_ARGS[@]}" > "$LOG" 2>&1 &
QPID=$!
# Show the console live without a pipe in the process tree.
tail -n +1 -f "$LOG" 2>/dev/null &
TPID=$!
# Wait for either qemu to exit on its own or the marker to appear, so a
# healthy boot does not burn the whole timeout.
for _ in $(seq 1 "$TIMEOUT"); do
    sleep 1
    if grep -qE "$EXPECT" "$LOG" 2>/dev/null; then
        log "marcador encontrado: $(grep -oE "$EXPECT" "$LOG" | head -1)"
        sleep 5
        kill "$TPID" 2>/dev/null || true
        pkill -P "$QPID" 2>/dev/null || true
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null
        exit 0
    fi
    kill -0 "$QPID" 2>/dev/null || break
done
kill "$TPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null
set -e

if grep -qE "$EXPECT" "$LOG" 2>/dev/null; then
    log "marcador encontrado: $(grep -oE "$EXPECT" "$LOG" | head -1)"
    exit 0
fi
warn "o sistema não alcançou o marcador esperado em ${TIMEOUT}s"
warn "últimas linhas do console:"
tail -20 "$LOG" | sed 's/^/  /'
exit 1
