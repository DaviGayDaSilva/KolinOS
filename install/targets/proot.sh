#!/data/data/com.termux/files/usr/bin/bash
# KolinOS install target: proot
#
# Installs the KolinOS rootfs as a proot-distro container. This is the Android /
# Termux path and needs NO root: proot implements the system calls in user space
# and proot-distro manages the container. It is the only supported way to "run"
# KolinOS on a phone today, because Android does not let you boot another Linux
# kernel (see docs/LIMITATIONS.md).
#
# Invoked by install/kolinos-install.sh, or directly:
#   bash install/targets/proot.sh [ARCHIVE.tar.xz] [options]
#
# Options:
#   --name NAME       Container name (default: kolinos)
#   --no-verify       Skip the SHA-256 check
#   --sha256 HASH     Expected SHA-256 of the archive
#   --bin-dir DIR     Where to write the 'kolinos' shortcut (default: $PREFIX/bin)
#   --yes             Assume yes for prompts
#   -h, --help        Show this help
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$_SELF_DIR/../lib/common.sh"

NAME="kolinos"
VERIFY=1
EXPECT_SHA=""
ARCHIVE=""
BIN_DIR=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)      NAME="$2"; shift 2 ;;
        --no-verify) VERIFY=0; shift ;;
        --sha256)    EXPECT_SHA="$2"; shift 2 ;;
        --bin-dir)   BIN_DIR="$2"; shift 2 ;;
        --yes)       KOLIN_ASSUME_YES=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*) die "opção desconhecida: $1" ;;
        *)  ARCHIVE="$1"; shift ;;
    esac
done

require_root_or_termux() {
    # proot needs no root, but proot-distro must be reachable.
    have proot-distro || die "proot-distro não encontrado. No Termux: pkg install proot-distro"
}

# ---------------------------------------------------------------------------
# 0. Environment checks
# ---------------------------------------------------------------------------
ENV_KIND="$(kolin_env)"
case "$ENV_KIND" in
    termux) : ;;
    linux|android) warn "ambiente '$ENV_KIND': proot-distro é incomum aqui. Prosseguindo." ;;
    *) warn "sistema não reconhecido; proot-distro é esperado" ;;
esac

[ "$(uname -m)" = "aarch64" ] || \
    warn "esta máquina é $(uname -m), não aarch64; o KolinOS é arm64 e pode ficar lento"

# In Termux, $PREFIX/bin holds the shortcut. Elsewhere, ~/.local/bin.
if [ -n "$PREFIX" ]; then
    BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
else
    BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
fi
mkdir -p "$BIN_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. Dependencies (proot-distro pulls in proot)
# ---------------------------------------------------------------------------
if ! have proot-distro; then
    have pkg || die "nem 'pkg' nem 'proot-distro' encontrados. No Termux: pkg install proot-distro"
    say "instalando proot-distro ..."
    pkg install -y proot-distro || die "falha ao instalar proot-distro"
fi
require_root_or_termux
if ! have proot && have pkg; then say "instalando proot ..."; pkg install -y proot || true; fi
have proot || die "proot não encontrado (Termux: pkg install proot; Debian: apt install proot)"

# ---------------------------------------------------------------------------
# 2. Locate + verify the rootfs archive
# ---------------------------------------------------------------------------
if [ -z "$ARCHIVE" ]; then
    ARCHIVE="$(kolin_find_archive || true)"
fi
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || die "rootfs não encontrado. Passe o caminho: $0 kolinos-*.tar.xz"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
say "rootfs: $ARCHIVE"
kolin_verify_archive "$ARCHIVE" "$EXPECT_SHA" "$VERIFY"

# ---------------------------------------------------------------------------
# 3. Detect proot-distro major version
# ---------------------------------------------------------------------------
PD_MODE="${KOLINOS_PD_MODE:-auto}"
if [ "$PD_MODE" = auto ]; then
    ver="$(proot-distro --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
    major="${ver%%.*}"
    if [ -n "$major" ] && [ "$major" -ge 5 ] 2>/dev/null; then
        PD_MODE=v5
    elif proot-distro --help 2>&1 | grep -qiE 'docker|oci'; then
        PD_MODE=v5
    elif [ -n "$PREFIX" ] && [ -d "$PREFIX/etc/proot-distro" ]; then
        PD_MODE=v4
    else
        PD_MODE=v5
    fi
fi
say "proot-distro: modo $PD_MODE"

# ---------------------------------------------------------------------------
# 4. Install the container
# ---------------------------------------------------------------------------
if proot-distro list 2>/dev/null | grep -qE "(^|\s)${NAME}(\s|$)"; then
    kolin_confirm "o container '$NAME' já existe. Remover e reinstalar?" || die "cancelado pelo usuário"
    say "removendo container existente '$NAME' ..."
    proot-distro remove "$NAME" >/dev/null 2>&1 || true
fi

if [ "$PD_MODE" = v5 ]; then
    say "instalando container '$NAME' a partir do arquivo local ..."
    proot-distro install --name "$NAME" "$ARCHIVE"
else
    PLUGIN_DIR="${PREFIX:-/etc}/etc/proot-distro"
    [ -n "$PREFIX" ] || die "modo v4 requer \$PREFIX (Termux)"
    mkdir -p "$PLUGIN_DIR"
    TARBALL_URL="${KOLIN_ROOTFS_URL:-file://$ARCHIVE}"
    cat > "$PLUGIN_DIR/${NAME}.sh" <<EOF
# KolinOS proot-distro plugin (v4 format), generated by install/targets/proot.sh
DISTRO_NAME="KolinOS"
DISTRO_COMMENT="KolinOS ${NAME}"
TARBALL_URL['aarch64']="${TARBALL_URL}"
TARBALL_SHA256['aarch64']="${EXPECT_SHA:-$(sha256sum "$ARCHIVE" | awk '{print $1}')}"
distro_setup() {
    run_proot_cmd touch /etc/kolinos/installed
}
EOF
    say "plugin v4 escrito em $PLUGIN_DIR/${NAME}.sh"
    if [ "$TARBALL_URL" = "file://$ARCHIVE" ]; then
        warn "v4: para usar o arquivo LOCAL, copie-o para um host acessível ou"
        warn "defina KOLIN_ROOTFS_URL para uma URL pública. Tentando mesmo assim ..."
    fi
    proot-distro install "$NAME"
fi

# ---------------------------------------------------------------------------
# 5. Convenience wrapper 'kolinos' in $BIN_DIR
# ---------------------------------------------------------------------------
WRAPPER="$BIN_DIR/kolinos"
if [ -n "$PREFIX" ]; then WRAP_SHELL="$PREFIX/bin/bash"; else WRAP_SHELL="/bin/bash"; fi
cat > "$WRAPPER" <<EOF
#!$WRAP_SHELL
# KolinOS launcher (generated by the installer).
if [ "\$#" -eq 0 ]; then
    exec proot-distro login $NAME
else
    exec proot-distro login $NAME -- "\$@"
fi
EOF
chmod +x "$WRAPPER"
ok "atalho criado: kolinos  (executa 'proot-distro login $NAME')"

# ---------------------------------------------------------------------------
# 6. First boot (runs inside the container, no root needed)
# ---------------------------------------------------------------------------
marker="/etc/kolinos/firstboot.done"
if proot-distro login "$NAME" -- /bin/sh -c "[ -x /usr/bin/kolinos-firstboot ] && [ ! -e $marker ]" 2>/dev/null; then
    say "executando o first boot pela primeira vez ..."
    proot-distro login "$NAME" -- /usr/bin/kolinos-firstboot \
        || warn "o first boot retornou erro; rode 'kolinos-firstboot' dentro do sistema"
fi

# ---------------------------------------------------------------------------
# 7. Verify the result
# ---------------------------------------------------------------------------
say "verificando a instalação ..."
if proot-distro login "$NAME" -- /bin/sh -c '. /etc/os-release; echo "$PRETTY_NAME"; echo "ID=$ID ID_LIKE=$ID_LIKE"'; then
    ok "KolinOS instalado com sucesso! Entre com: kolinos"
else
    die "o container foi instalado mas não respondeu; tente: proot-distro login $NAME"
fi
