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
check "apt tuning aplicado"    'grep -q "Install-Recommends \"false\"" /etc/apt/apt.conf.d/99kolinos && echo ok'
check "repo KolinOS inativo"   'test -f /etc/apt/sources.list.d/kolinos.sources.disabled && echo ok'

printf '\nIdentidade visual (FASE 3):\n'
check "paleta presente"        'test -f /etc/kolinos/branding/palette.txt && echo ok'
check "logo do corvo"          'grep -q "██████" /etc/kolinos/branding/logo.txt && echo ok'
check "tokens de cor"          '. /etc/kolinos/colors.sh; echo "primary=$KOLIN_COLOR_PRIMARY accent=$KOLIN_COLOR_ACCENT"'
check "kolinos-info completo"  'kolinos-info 2>/dev/null | grep -q "^  Base" && echo ok'
check "motd com branding"      'grep -q "██████" /etc/motd && echo ok'
if kolin_run "$R" 'grep -rIl "@KOLIN_" /etc /usr/bin /usr/lib/os-release 2>/dev/null | grep -q .' >/dev/null 2>&1; then
    printf '  \033[1;31m✗\033[0m placeholders @KOLIN_* não renderizados (FALHOU)\n'; fail=1
else
    printf '  \033[1;32m✔\033[0m nenhum placeholder @KOLIN_* pendente\n'
fi

printf '\nBase mínima (FASE 2):\n'
check "machine-id vazio"       'test ! -s /etc/machine-id && echo vazio'
check "resolv.conf de runtime" 'grep -q "managed at runtime" /etc/resolv.conf && echo ok'
check "fstab presente"         'test -f /etc/fstab && echo ok'
check "locale configurado"     'grep -q "^LANG=" /etc/default/locale && grep "^LANG=" /etc/default/locale'
check "timezone definido"      'test -e /etc/localtime && echo "$(cat /etc/timezone)"'
check "copyright preservado"   'test -d /usr/share/doc && ls /usr/share/doc | head -1'
if kolin_run "$R" 'test -d /usr/share/man && [ -n "$(ls -A /usr/share/man 2>/dev/null)"' >/dev/null 2>&1; then
    printf '  \033[1;33m•\033[0m modo --full: man pages presentes (esperado)\n'
else
    printf '  \033[1;32m✔\033[0m modo slim: man pages removidas\n'
fi

printf '\nUsuário:\n'
check "usuário padrão existe"  "id ${KOLIN_DEFAULT_USER}"
check "sudo configurado"       "test -f /etc/sudoers.d/90-kolinos && echo ok"
check "grupo sudo"             "id -nG ${KOLIN_DEFAULT_USER}"

printf '\nPacotes próprios (FASE 5):\n'
check "kolinos-base instalado"   'dpkg-query -W -f="\${Version} \${Architecture}" kolinos-base'
check "kolinos-tools instalado"  'dpkg-query -W -f="\${Version} \${Architecture}" kolinos-tools'
check "kolinos-branding instalado" 'dpkg-query -W -f="\${Version} \${Architecture}" kolinos-branding'
check "tools pertencem ao dpkg"  'dpkg -S /usr/bin/kolinos-info'
check "dpkg -V limpo (tools)"    'dpkg -V kolinos-tools && echo ok'
check "apt-kolinos presente"     'command -v apt-kolinos >/dev/null && apt-kolinos status'
check "repo remoto desativado"   'test -f /etc/apt/sources.list.d/kolinos.sources.disabled && echo ok'

printf '\nInstalação (FASE 6):\n'
check "kolinos-firstboot presente" 'command -v kolinos-firstboot >/dev/null && echo ok'
check "firstboot pertence ao dpkg" 'dpkg -S /usr/bin/kolinos-firstboot'
check "gancho de first boot no profile" 'test -x /usr/bin/kolinos-firstboot && grep -q kolinos-firstboot /etc/profile.d/kolinos-firstboot.sh && echo ok'
check "first boot ainda não executado" 'test ! -e /etc/kolinos/firstboot.done && echo "pendente (esperado na imagem)"'
# A build-time file:// repo must not leak into the shipped image.
if kolin_run "$R" 'ls /etc/apt/sources.list.d/*kolinos-build* 2>/dev/null | grep -q .'; then
    printf '  \033[1;31m✗\033[0m repo de build vazou para o rootfs (FALHOU)\n'; fail=1
else
    printf '  \033[1;32m✔\033[0m repo de build removido do rootfs\n'
fi

printf '\nArquitetura esperada: %s\n\n' "$KOLIN_ARCH"
if [ "$fail" -ne 0 ]; then die "verificação encontrou falhas"; fi
log "todas as verificações passaram"
printf '\nPara entrar no rootfs (host, com root): sudo bash %s/scripts/host/enter.sh\n' "$ROOT"
