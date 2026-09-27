#!/usr/bin/env bash
# verify-rootfs.sh — sanity-check a built KolinOS rootfs (host side, needs root
# and qemu-user-static for cross-arch). Prints a report and exits non-zero if a
# hard check fails.
#
# Usage: sudo bash scripts/host/verify-rootfs.sh [rootfs-dir]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../build/lib/common.sh
source "$ROOT/build/lib/common.sh"

R="${1:-$ROOT/rootfs}"
[ -d "$R" ] || die "rootfs não encontrado: $R"

fail=0
check() { # check <description> <command...>
    local desc="$1"; shift
    if kolin_run "$R" "$*" >/tmp/kolinos-verify.out 2>&1; then
        printf '  \033[1;32m✔\033[0m %s: %s\n' "$desc" "$(head -1 /tmp/kolinos-verify.out)"
    else
        printf '  \033[1;31m\u2717\033[0m %s (FALHOU)\n' "$desc"; fail=1
    fi
}

log "verificando rootfs em $R"
printf '\nIdentidade:\n'
check "os-release PRETTY_NAME" '. /etc/os-release; echo "$PRETTY_NAME"'
check "os-release ID"          '. /etc/os-release; echo "$ID / $ID_LIKE"'
check "hostname"               'cat /etc/hostname'
check "motd presente"          'grep -q KolinOS /etc/motd && echo ok'
check "ferramenta kolinos-info" 'command -v kolinos-info >/dev/null && kolinos-info | head -3'
check "ferramenta kolinos-version" 'kolinos-version'

printf '\nBase:\n'
check "dpkg operacional"       'dpkg --print-architecture'
check "apt operacional"        'apt-get --version | head -1'
check "contagem de pacotes"    'dpkg-query -f ".\n" -W | wc -l'
check "sources.list"           'grep -c "^deb" /etc/apt/sources.list'

printf '\nUsuário:\n'
check "usuário padrão existe"  "id ${KOLIN_DEFAULT_USER}"
check "sudo configurado"       "test -f /etc/sudoers.d/90-kolinos && echo ok"
check "grupo sudo"             "id -nG ${KOLIN_DEFAULT_USER}"

printf '\nArquitetura esperada: %s\n\n' "$KOLIN_ARCH"
if [ "$fail" -ne 0 ]; then die "verificação encontrou falhas"; fi
log "todas as verificações passaram"
printf '\nPara entrar no rootfs (host, com root): sudo bash %s/scripts/host/enter.sh\n' "$ROOT"
