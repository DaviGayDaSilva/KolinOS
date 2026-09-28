#!/usr/bin/env bash
# apt-client-test.sh — verify the KolinOS APT repository end to end (FASE 9).
#
# Builds a throwaway APT client rooted at a temporary directory and runs a real
# `apt-get update` against the built repository. The point is to prove the
# signature chain actually validates: that the public key in
# config/apt/trusted.gpg.d/kolinos.gpg verifies the Release produced by
# build-repo.sh, and that APT accepts it. A repository that "builds" is not the
# same as one APT will trust.
#
# It uses a private Dir tree rather than chroot, so it needs no root and cannot
# touch the host's APT state.
#
# Usage: bash scripts/host/verify-repo.sh [--url <url>] [--arch arm64]
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"
CODENAME="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"
ARCH="${KOLIN_DEB_ARCH:-$KOLIN_ARCH}"
URL=""
RC=0

log()  { printf '[verify-repo] %s\n' "$*"; }
pass() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FALHA] %s\n' "$*"; RC=1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --url)  URL="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'opção desconhecida: %s\n' "$1" >&2; exit 2 ;;
    esac
done

PUB="$ROOT/repo/public"
KEY="$ROOT/config/apt/trusted.gpg.d/kolinos.gpg"
[ -n "$URL" ] || URL="file:$PUB"

[ -d "$PUB" ] || { printf 'repositório não construído: %s\n' "$PUB" >&2; exit 1; }
[ -f "$KEY" ] || { printf 'chave pública ausente: %s\n' "$KEY" >&2; exit 1; }

log "repositório: $URL ($CODENAME/$ARCH)"

# --- 1. the Release file carries the expected identity ---------------------
REL="$PUB/dists/$CODENAME/Release"
[ -f "$REL" ] && pass "Release presente" || fail "Release ausente"
if [ -f "$REL" ]; then
    grep -q "^Origin: KolinOS"  "$REL" && pass "Origin: KolinOS"  || fail "Origin errado"
    grep -q "^Suite: $CODENAME" "$REL" && pass "Suite: $CODENAME" || fail "Suite errado"
    grep -q "^Architectures: .*$ARCH" "$REL" \
        && pass "Architectures inclui $ARCH" || fail "Architectures não inclui $ARCH"
fi

# --- 2. both signatures verify against the *public* key -------------------
if [ -f "$PUB/dists/$CODENAME/Release.gpg" ] && [ -f "$PUB/dists/$CODENAME/InRelease" ]; then
    VG="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-vg.XXXXXX")"
    chmod 0700 "$VG"
    GNUPGHOME="$VG" gpg --batch --quiet --import "$KEY" 2>/dev/null || true
    if GNUPGHOME="$VG" gpg --batch --verify \
            "$PUB/dists/$CODENAME/Release.gpg" "$REL" >/dev/null 2>&1; then
        pass "Release.gpg verifica com a chave pública"
    else
        fail "Release.gpg NÃO verifica"
    fi
    if GNUPGHOME="$VG" gpg --batch --verify "$PUB/dists/$CODENAME/InRelease" >/dev/null 2>&1; then
        pass "InRelease verifica com a chave pública"
    else
        fail "InRelease NÃO verifica"
    fi
    rm -rf "$VG"
else
    fail "Release.gpg ou InRelease ausente (repositório não assinado?)"
fi

# --- 3. a real apt-get update accepts it ---------------------------------
log "apt-get update contra $URL"
CLIENT="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-apt.XXXXXX")"
trap 'rm -rf "$CLIENT"' EXIT
mkdir -p "$CLIENT/etc/apt/sources.list.d" "$CLIENT/etc/apt/trusted.gpg.d" \
         "$CLIENT/etc/apt/preferences.d" \
         "$CLIENT/var/lib/apt/lists/partial" \
         "$CLIENT/var/cache/apt/archives/partial" "$CLIENT/var/lib/dpkg"
: > "$CLIENT/var/lib/dpkg/status"
cp "$KEY" "$CLIENT/etc/apt/trusted.gpg.d/kolinos.gpg"

# The repository targets one architecture, which is usually not the host's.
# APT only considers packages for the native architecture unless the
# repository's architecture is declared as foreign, so a repo that is perfectly
# valid reports "Unable to locate package" without this line. That is a property
# of the *test client*, not of the repository.
if [ "$ARCH" != "$(dpkg --print-architecture)" ]; then
    echo "$ARCH" > "$CLIENT/var/lib/dpkg/arch"
    log "arquitetura estrangeira declarada no cliente: $ARCH"
fi

cat > "$CLIENT/etc/apt/sources.list.d/kolinos.list" <<EOF
deb [signed-by=$CLIENT/etc/apt/trusted.gpg.d/kolinos.gpg] $URL $CODENAME main
EOF

APT_OPTS=(-o "Dir=$CLIENT" -o "Dir::Etc=$CLIENT/etc/apt"
          -o "Dir::State=$CLIENT/var/lib/apt"
          -o "Dir::Cache=$CLIENT/var/cache/apt"
          -o "Dir::State::status=$CLIENT/var/lib/dpkg/status"
          -o "APT::Get::List-Cleanup=0")

if apt-get "${APT_OPTS[@]}" update > "$CLIENT/update.log" 2>&1; then
    pass "apt-get update concluiu"
    grep -q "$CODENAME" "$CLIENT/update.log" \
        && pass "APT buscou a suíte $CODENAME" || true
else
    fail "apt-get update falhou"
    sed 's/^/         /' "$CLIENT/update.log" >&2
fi

# --- 4. every .deb in the index is actually downloadable ------------------
mapfile -t PKGS < <(grep -h '^Package:' "$PUB/dists/$CODENAME/main/binary-$ARCH/Packages" \
                     | awk '{print $2}' | sort)
if [ "${#PKGS[@]}" -gt 0 ]; then
    pass "${#PKGS[@]} pacotes no índice: ${PKGS[*]}"
else
    fail "índice sem pacotes"
fi

# Verify the packaged payload is reachable, not just indexed. apt-get download
# refuses to install a foreign architecture, so the repository is re-declared as
# trusted for this one step: the signature was already proven in step 2, which
# is what this check is *not* about.
mkdir -p "$CLIENT/var/cache/apt/archives/partial"
for p in "${PKGS[@]:-}"; do
    [ -n "$p" ] || continue
    ( cd "$CLIENT" && apt-get "${APT_OPTS[@]}" \
        -o "Dir::State::lists=$CLIENT/var/lib/apt/lists" \
        -o APT::Architecture="$ARCH" \
        download "$p" >/dev/null 2>&1 )
    if ls "$CLIENT"/*_"$p"_*.deb >/dev/null 2>&1 || ls "$CLIENT"/*"$p"*.deb >/dev/null 2>&1; then
        pass "baixado via APT: $p"
    else
        fail "não foi possível baixar $p via APT (arquivo/índice inconsistente?)"
    fi
    rm -f "$CLIENT"/*.deb
done

echo
if [ "$RC" -eq 0 ]; then
    log "repositório APT OK"
else
    log "repositório APT com falhas"
fi
exit "$RC"
