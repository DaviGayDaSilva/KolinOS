#!/data/data/com.termux/files/usr/bin/bash
# KolinOS installer for Termux (Android, arm64, NO ROOT REQUIRED).
#
# Installs the personalized KolinOS ARM64 rootfs as a proot-distro container.
#
# Usage:
#   bash install.sh [ROOTFS.tar.xz] [options]
#
# Options:
#   --name NAME       Container name (default: kolinos)
#   --no-verify       Skip the SHA-256 check even if SHA256SUMS is present
#   --sha256 HASH     Expected SHA-256 of the rootfs archive
#   -h, --help        Show this help
#
# Notes:
#   * Works on Termux aarch64. On x86_64 Termux the archive still extracts, but
#     KolinOS is arm64-first: expect slowness under QEMU emulation.
#   * proot-distro v5 installs from a local rootfs archive directly.
#   * proot-distro v4 uses a plugin file; this script writes one if needed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit if you host the rootfs yourself.
# ---------------------------------------------------------------------------
KOLIN_ROOTFS_URL=""          # e.g. https://github.com/USER/KolinOS/releases/download/v1.0.0/kolinos-...tar.xz

NAME="kolinos"
VERIFY=1
EXPECT_SHA=""
ARCHIVE=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)     NAME="$2"; shift 2 ;;
        --no-verify) VERIFY=0; shift ;;
        --sha256)   EXPECT_SHA="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        -*) printf 'opção desconhecida: %s\n' "$1" >&2; exit 1 ;;
        *)  ARCHIVE="$1"; shift ;;
    esac
done

say()  { printf '\033[1;35m[KolinOS]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[KolinOS]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[KolinOS][erro]\033[0m %s\n' "$*" >&2; exit 1; }

# Termux defines $PREFIX; fall back sensibly on plain Linux (testing).
PREFIX="${PREFIX:-}"
if [ -n "$PREFIX" ]; then
    KOLIN_BIN_DIR="$PREFIX/bin"
else
    KOLIN_BIN_DIR="$HOME/.local/bin"
fi
mkdir -p "$KOLIN_BIN_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 0. Environment checks
# ---------------------------------------------------------------------------
case "${PREFIX:-}" in
    *com.termux*) : ;;
    *) warn "Isto não parece ser um Termux (\$PREFIX não definido). Prosseguindo, mas proot-distro é esperado." ;;
esac

if [ "$(uname -m)" != "aarch64" ]; then
    warn "Esta máquina é $(uname -m), não aarch64. O KolinOS é arm64; pode ficar lento ou não funcionar."
fi

if ! command -v pkg >/dev/null 2>&1; then
    if command -v proot-distro >/dev/null 2>&1; then
        warn "'pkg' não encontrado (ambiente não-Termux); usando o proot-distro já instalado."
    else
        die "nem 'pkg' nem 'proot-distro' encontrados. No Termux rode: pkg install proot-distro"
    fi
fi

# ---------------------------------------------------------------------------
# 1. Dependencies (proot-distro pulls in proot)
# ---------------------------------------------------------------------------
if ! command -v proot-distro >/dev/null 2>&1; then
    say "Instalando proot-distro via pkg ..."
    pkg install -y proot-distro || die "falha ao instalar proot-distro"
fi
command -v proot >/dev/null 2>&1 || [ ! -x "${PREFIX:-}/bin/pkg" ] || { say "Instalando proot ..."; pkg install -y proot; }
command -v proot >/dev/null 2>&1 || die "proot não encontrado (Termux: pkg install proot; Debian: apt install proot)"

# ---------------------------------------------------------------------------
# 2. Locate the rootfs archive (argument, sibling dir, or download)
# ---------------------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$ARCHIVE" ]; then
    for cand in \
        "$SELF_DIR"/../../rootfs/kolinos-*.tar.xz \
        "$SELF_DIR/kolinos-"*.tar.xz \
        "$PWD"/kolinos-*.tar.xz; do
        [ -f "$cand" ] && ARCHIVE="$cand" && break
    done
fi
if [ -z "$ARCHIVE" ] && [ -n "$KOLIN_ROOTFS_URL" ]; then
    DL_DIR="$(mktemp -d 2>/dev/null || echo /tmp)"
    ARCHIVE="$DL_DIR/$(basename "$KOLIN_ROOTFS_URL")"
    say "Baixando rootfs de $KOLIN_ROOTFS_URL ..."
    command -v curl >/dev/null 2>&1 || pkg install -y curl
    curl -fL --retry 3 -o "$ARCHIVE" "$KOLIN_ROOTFS_URL"
fi
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || die "rootfs não encontrado. Passe o caminho: bash install.sh kolinos-*.tar.xz"
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
say "Rootfs: $ARCHIVE"

# ---------------------------------------------------------------------------
# 3. Verify checksum
# ---------------------------------------------------------------------------
if [ "$VERIFY" = 1 ]; then
    if [ -n "$EXPECT_SHA" ]; then
        got="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
        [ "$got" = "$EXPECT_SHA" ] || die "checksum não confere! esperado $EXPECT_SHA, obtido $got"
        say "Checksum OK"
    elif [ -f "$SELF_DIR/../../SHA256SUMS" ]; then
        base="$(basename "$ARCHIVE")"
        exp="$(awk -v f="$base" '$2==f || $2=="./"f {print $1}' "$SELF_DIR/../../SHA256SUMS" | head -1)"
        if [ -n "$exp" ]; then
            got="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
            [ "$got" = "$exp" ] || die "checksum não confere para $base"
            say "Checksum OK"
        else
            warn "SHA256SUMS encontrado mas sem entrada para $base"
        fi
    else
        warn "Sem checksum disponível para verificar"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Detect proot-distro major version
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
# 5. Install the container
# ---------------------------------------------------------------------------
# Remove a previous KolinOS container with the same name.
if proot-distro list 2>/dev/null | grep -qE "(^|\s)${NAME}(\s|$)"; then
    say "Removendo container existente '$NAME' ..."
    proot-distro remove "$NAME" >/dev/null 2>&1 || true
fi

if [ "$PD_MODE" = v5 ]; then
    say "Instalando container '$NAME' a partir do arquivo local ..."
    proot-distro install --name "$NAME" "$ARCHIVE"
else
    # proot-distro v4: write a plugin that points at the local/home-hosted tarball.
    PLUGIN_DIR="${PREFIX:-/etc}/etc/proot-distro"
    [ -n "$PREFIX" ] || die "modo v4 requer \$PREFIX (Termux)"
    mkdir -p "$PLUGIN_DIR"
    TARBALL_URL="${KOLIN_ROOTFS_URL:-file://$ARCHIVE}"
    cat > "$PLUGIN_DIR/${NAME}.sh" <<EOF
# KolinOS proot-distro plugin (v4 format), generated by install.sh
DISTRO_NAME="KolinOS"
DISTRO_COMMENT="KolinOS ${NAME}"
TARBALL_URL['aarch64']="${TARBALL_URL}"
TARBALL_SHA256['aarch64']="${EXPECT_SHA:-$(sha256sum "$ARCHIVE" | awk '{print $1}')}"
distro_setup() {
    run_proot_cmd touch /etc/kolinos/installed
}
EOF
    say "Plugin v4 escrito em $PLUGIN_DIR/${NAME}.sh"
    if [ "$TARBALL_URL" = "file://$ARCHIVE" ]; then
        warn "v4: para usar o arquivo LOCAL, copie-o para um host acessível ou"
        warn "defina KOLIN_ROOTFS_URL no topo deste script para uma URL pública."
        warn "Tentando 'proot-distro install' mesmo assim ..."
    fi
    proot-distro install "$NAME"
fi

# ---------------------------------------------------------------------------
# 6. Convenience wrapper 'kolinos' in $PREFIX/bin
# ---------------------------------------------------------------------------
WRAPPER="$KOLIN_BIN_DIR/kolinos"
if [ -n "$PREFIX" ]; then WRAP_SHELL="/data/data/com.termux/files/usr/bin/bash"; else WRAP_SHELL="/bin/bash"; fi
cat > "$WRAPPER" <<EOF
#!$WRAP_SHELL
if [ "\$#" -eq 0 ]; then
    exec proot-distro login $NAME
else
    exec proot-distro login $NAME -- "\$@"
fi
EOF
chmod +x "$WRAPPER"
say "Atalho criado: kolinos  (executa 'proot-distro login $NAME')"

# ---------------------------------------------------------------------------
# 7. Verify the result
# ---------------------------------------------------------------------------
say "Verificando a instalação ..."
if proot-distro login "$NAME" -- /bin/sh -c '. /etc/os-release; echo "$PRETTY_NAME"; echo "ID=$ID ID_LIKE=$ID_LIKE"'; then
    say "KolinOS instalado com sucesso! Entre com: kolinos"
else
    die "o container foi instalado mas não respondeu; tente: proot-distro login $NAME"
fi
