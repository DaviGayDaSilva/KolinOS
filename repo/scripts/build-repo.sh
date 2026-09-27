#!/usr/bin/env bash
# build-repo.sh — build a local APT repository from .deb files (Phase 9).
#
# This is the groundwork for KolinOS's own APT repository. It does NOT publish
# anything: it produces a signed (or optionally unsigned) local repository tree
# under repo/public/ that can be served over HTTP or a file:// URL, or pushed
# to a static host later.
#
# Usage: sudo bash scripts/build-repo.sh [--unsigned] [--deb-file <f.deb>|--debs-dir <d>]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"
CODENAME="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"

UNSIGNED=0
DEBS_DIR="$ROOT/packages/custom/debs"

log()  { printf '[repo] %s\n' "$*"; }
warn() { printf '[repo][aviso] %s\n' "$*" >&2; }
die()  { printf '[repo][erro] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --unsigned) UNSIGNED=1; shift ;;
        --debs-dir) DEBS_DIR="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "opção desconhecida: $1" ;;
    esac
done

have dpkg-scanpackages || die "instale 'dpkg-dev' (fornece dpkg-scanpackages)"
have apt-ftparchive   || die "instale 'apt-utils' (fornece apt-ftparchive)"

PUB="$ROOT/repo/public"
POOL="$PUB/pool/main"
DIST="$PUB/dists/$CODENAME/main/binary-arm64"
mkdir -p "$POOL" "$DIST"

mapfile -t DEBS < <(find "$DEBS_DIR" -maxdepth 1 -name '*.deb' 2>/dev/null | sort)
if [ "${#DEBS[@]}" -eq 0 ]; then
    warn "nenhum .deb em $DEBS_DIR — criando repositório vazio (ok para testes de layout)"
fi

# Copy .deb files into the pool under their real names.
for d in "${DEBS[@]:-}"; do
    [ -f "$d" ] || continue
    cp -v "$d" "$POOL/"
done

log "indexando $POOL ..."
( cd "$PUB" && dpkg-scanpackages -m pool /dev/null > "dists/$CODENAME/main/binary-arm64/Packages" 2>/dev/null )
gzip -kf "$DIST/Packages"
xz -kf  "$DIST/Packages"

# Release file for the suite.
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="KolinOS" \
    -o APT::FTPArchive::Release::Label="KolinOS" \
    -o APT::FTPArchive::Release::Suite="$CODENAME" \
    -o APT::FTPArchive::Release::Codename="$CODENAME" \
    -o APT::FTPArchive::Release::Architectures="arm64" \
    -o APT::FTPArchive::Release::Components="main" \
    release "$PUB/dists/$CODENAME" > "$PUB/dists/$CODENAME/Release"

if [ "$UNSIGNED" = 1 ]; then
    log "repositório NÃO assinado (use --unsigned apenas para testes locais)"
else
    KEY="${KOLIN_APT_KEY:-$ROOT/repo/keys/kolinos.gpg}"
    if [ -f "$KEY" ]; then
        log "assinando Release com $KEY"
        gpg --batch --yes --armor --detach-sign -u "$KEY" -o "$PUB/dists/$CODENAME/Release.gpg" "$PUB/dists/$CODENAME/Release"
        gpg --batch --yes --clearsign   -u "$KEY" -o "$PUB/dists/$CODENAME/InRelease"   "$PUB/dists/$CODENAME/Release"
    else
        warn "chave ausente em $KEY — rode 'make-gpg-key.sh' ou use --unsigned"
    fi
fi

log "repositório pronto em $PUB"
log "sirva com: (cd $PUB && python3 -m http.server 8080)"
log "no KolinOS: deb [signed-by=/etc/apt/trusted.gpg.d/kolinos.gpg] http://<host>:8080 $CODENAME main"
