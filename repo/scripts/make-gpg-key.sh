#!/usr/bin/env bash
# make-gpg-key.sh — create the KolinOS APT signing key (Phase 9 groundwork).
#
# Creates an Ed25519 signing key in repo/keys/ and exports the public key to
# config/apt/trusted.gpg.d/kolinos.gpg so the rootfs can trust the repository.
#
# Usage: bash repo/scripts/make-gpg-key.sh
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
KEYS="$ROOT/repo/keys"
mkdir -p "$KEYS" "$ROOT/config/apt/trusted.gpg.d"

if [ -f "$KEYS/kolinos.gpg" ]; then
    echo "[repo] chave já existe: $KEYS/kolinos.gpg"
else
    echo "[repo] gerando chave Ed25519 (sem passphrase, para automação) ..."
    gpg --batch --yes --quick-generate-key \
        "KolinOS APT Repository <repo@kolinos.org>" ed25519 sign never
fi

echo "[repo] exportando chave pública ..."
gpg --batch --yes --export "repo@kolinos.org" > "$ROOT/config/apt/trusted.gpg.d/kolinos.gpg"
echo "[repo] chave pública: config/apt/trusted.gpg.d/kolinos.gpg"
gpg --with-colons --fingerprint "repo@kolinos.org" | awk -F: '/^fpr:/{print "  fingerprint: "$10}'
