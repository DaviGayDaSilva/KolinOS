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
    # --pinentry-mode loopback plus an empty --passphrase is what makes this
    # non-interactive. Without it gpg still opens a pinentry prompt asking to
    # confirm the empty passphrase, which hangs a build or CI job forever:
    # --batch alone is not enough for key generation.
    gpg --batch --yes --pinentry-mode loopback --passphrase '' \
        --quick-generate-key \
        "KolinOS APT Repository <repo@kolinos.org>" ed25519 sign never
fi

echo "[repo] exportando chave pública ..."
gpg --batch --yes --export "repo@kolinos.org" > "$ROOT/config/apt/trusted.gpg.d/kolinos.gpg"
echo "[repo] chave pública: config/apt/trusted.gpg.d/kolinos.gpg"
gpg --batch --with-colons --fingerprint "repo@kolinos.org" \
    | awk -F: '/^fpr:/{print "  fingerprint: "$10; exit}'

# Also export the *secret* key to repo/keys/, which build-repo.sh signs with.
# That directory is gitignored: the private key must never be committed. The
# export exists so a CI job or a second machine can sign without the key being
# generated again (which would change the fingerprint and break every client
# that already trusts the published public key).
echo "[repo] exportando chave privada para $KEYS/kolinos.gpg ..."
gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --export-secret-keys "repo@kolinos.org" > "$KEYS/kolinos.gpg"
chmod 0600 "$KEYS/kolinos.gpg"
echo "[repo] chave privada: $KEYS/kolinos.gpg (não versionada — mantenha em seguro)"
