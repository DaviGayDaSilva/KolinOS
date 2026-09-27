#!/usr/bin/env bash
# verify-installer.sh — exercise the Phase 6 installer without a phone.
#
# The installer is mostly shell logic (environment detection, the one-command
# front-end, safety guards, checksum handling), so it can be tested natively on
# the host, even when the rootfs itself is a foreign architecture that the host
# cannot execute. This script checks the parts that do not need to run the
# target: --help, backend dispatch, argument forwarding, and the destructive
# guards. It never partitions, never mounts and never writes a rootfs.
#
# Usage: bash scripts/host/verify-installer.sh [--dest DIR]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"

DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'opção desconhecida: %s\n' "$1" >&2; exit 2 ;;
    esac
done

fail=0
pass() { printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s (FALHOU)\n' "$*"; fail=1; }

run_ok()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else bad "$desc"; fi; }
run_bad() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$desc"; else pass "$desc"; fi; }

printf 'Instalador (FASE 6):\n'

# --- front-end exists and documents itself ---------------------------------
run_ok "front-end existe"           test -f "$ROOT/install/kolinos-install.sh"
for b in proot dir disk; do
    run_ok "backend $b existe"      test -f "$ROOT/install/targets/$b.sh"
    run_ok "backend $b --help"      bash "$ROOT/install/targets/$b.sh" --help
done
run_ok "front-end --help"           bash "$ROOT/install/kolinos-install.sh" --help

# --- front-end rejects nonsense before doing anything ----------------------
run_bad "front-end rejeita --target inválido" \
    bash "$ROOT/install/kolinos-install.sh" --target nonsense

# --- destructive guards (no root needed to reach them) ---------------------
run_bad "disk exige --device" \
    bash "$ROOT/install/targets/disk.sh" --force --yes
run_bad "dir exige --dest" \
    bash "$ROOT/install/targets/dir.sh"

# A non-empty directory must be refused (guards run before extraction).
if [ -n "$DEST" ]; then
    mkdir -p "$DEST"
    run_bad "dir recusa destino não vazio" \
        bash "$ROOT/install/targets/dir.sh" --dest "$DEST" --no-firstboot
    run_bad "guarda de caminho perigoso" \
        bash -c 'set -e; . "'"$ROOT"'/install/lib/common.sh"; kolin_guard_empty_dir /'
fi

# --- checksum helpers: a truncated archive must fail verification ----------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
head -c 4096 /dev/urandom > "$tmp/kolinos-fake.tar.xz"
printf '%s  kolinos-fake.tar.xz\n' "$(sha256sum "$tmp/kolinos-fake.tar.xz" | awk '{print $1}')" \
    > "$tmp/SHA256SUMS"
run_ok "checksum válido passa" \
    bash -c '. "'"$ROOT"'/install/lib/common.sh"; kolin_verify_archive "'"$tmp"'/kolinos-fake.tar.xz" "" 1'
run_bad "checksum inválido falha" \
    bash -c '. "'"$ROOT"'/install/lib/common.sh"; kolin_verify_archive "'"$tmp"'/kolinos-fake.tar.xz" deadbeef 1'

# --- first boot tool is syntactically sound --------------------------------
run_ok "kolinos-firstboot --help/syntax" bash -n "$ROOT/tools/kolinos-firstboot"

if [ "$fail" -eq 0 ]; then
    printf '\033[1;32m[KolinOS]\033[0m verificações do instalador passaram\n'
else
    printf '\033[1;31m[KolinOS]\033[0m erro: verificações do instalador falharam\n' >&2
fi
exit "$fail"
