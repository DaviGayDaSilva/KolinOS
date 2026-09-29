#!/usr/bin/env bash
# release.sh — publish the KolinOS artifacts as a GitHub release.
#
# This exists because the release is the only place the distribution is actually
# consumed from: a commit or a tag is not downloadable, an asset is. The script
# keeps the manifest, the tag and the assets consistent, which is the part that
# is easy to get wrong by hand — an asset whose bytes no longer match
# SHA256SUMS is worse than a missing one.
#
# It refuses to publish a release whose tag does not point at HEAD, whose
# working tree is dirty, or whose artifacts fail their own checksums. A release
# that lies about its contents is the failure mode worth blocking.
#
# Usage:
#   bash scripts/artifacts/release.sh --tag v1.0.0 [options]
#
# Options:
#   --tag TAG       Release tag (required). Must exist, or --create-tag is given.
#   --title TITLE   Release title (default: "KolinOS <version> (<codename>)")
#   --notes FILE    Markdown file with the release body
#   --create-tag    Create an annotated tag at HEAD if it does not exist
#   --draft         Publish as a draft
#   --prerelease    Mark as a pre-release
#   --repo OWNER/R  Override the repository (default: derived from git remote)
#   --allow-tag-mismatch  Publish even if the tag does not point at HEAD
#   --no-verify     Skip the artifact checksum verification (discouraged)
#   -h, --help      Show this help
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_SELF_DIR/../.." && pwd)"
# shellcheck source=../../build/lib/common.sh
. "$ROOT_DIR/build/lib/common.sh"
# shellcheck source=../../VERSION
. "$ROOT_DIR/VERSION"

TAG=""
TITLE=""
NOTES=""
CREATE_TAG=0
DRAFT=0
PRERELEASE=0
REPO=""
VERIFY=1
ALLOW_TAG_MISMATCH=0

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)         TAG="$2"; shift 2 ;;
        --title)       TITLE="$2"; shift 2 ;;
        --notes)       NOTES="$2"; shift 2 ;;
        --create-tag)  CREATE_TAG=1; shift ;;
        --draft)       DRAFT=1; shift ;;
        --prerelease)  PRERELEASE=1; shift ;;
        --repo)        REPO="$2"; shift 2 ;;
        --allow-tag-mismatch) ALLOW_TAG_MISMATCH=1; shift ;;
        --no-verify)   VERIFY=0; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) die "opção desconhecida: $1 (veja --help)" ;;
    esac
done

[ -n "$TAG" ] || die "--tag é obrigatório (veja --help)"
have gh || die "gh ausente (https://cli.github.com)"
have sha256sum || die "sha256sum ausente (coreutils)"

# build.sh exports KOLIN_OUTPUT_DIR; when this script is run standalone it is
# not set, and VERSION/common.sh do not define it either — so default it here.
OUT_DIR="${KOLIN_OUTPUT_DIR:-$ROOT_DIR/output}"
[ -d "$OUT_DIR" ] || die "diretório de artefatos ausente: $OUT_DIR (rode o build primeiro)"

# Derive OWNER/REPO from the remote so the default cannot drift from the clone
# being published.
if [ -z "$REPO" ]; then
    url="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
    [ -n "$url" ] || die "sem remote origin; use --repo OWNER/NOME"
    REPO="$(printf '%s' "$url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
fi
case "$REPO" in
    */*) ;;
    *) die "repositório inválido: $REPO (esperado OWNER/NOME)" ;;
esac

TITLE="${TITLE:-$KOLIN_NAME $KOLIN_VERSION ($KOLIN_CODENAME)}"

cd "$ROOT_DIR"

# --- guarantees before anything leaves this machine -------------------------

if [ "$VERIFY" = 1 ]; then
    [ -f "$OUT_DIR/SHA256SUMS" ] || die "SHA256SUMS ausente em $OUT_DIR"
    log "verificando os checksums dos artefatos"
    # Run from OUT_DIR: the manifest holds bare filenames.
    ( cd "$OUT_DIR" && sha256sum -c --quiet SHA256SUMS ) \
        || die "um artefato não confere com SHA256SUMS; não publique"
    log "todos os artefatos conferem"
fi

if [ "$CREATE_TAG" = 1 ]; then
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        log "tag $TAG já existe; mantendo"
    else
        log "criando tag anotada $TAG em HEAD"
        git tag -a "$TAG" -m "$TITLE"
    fi
fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || die "tag $TAG não existe (use --create-tag para criá-la em HEAD)"

# The tag is what the release claims to describe. If it is not HEAD, the assets
# in output/ were almost certainly built from a different commit, and publishing
# them would attach the wrong binaries to the tag.
TAG_COMMIT="$(git rev-list -n1 "$TAG")"
HEAD_COMMIT="$(git rev-parse HEAD)"
if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    if [ "$ALLOW_TAG_MISMATCH" = 1 ]; then
        warn "a tag $TAG aponta para $TAG_COMMIT, não para HEAD ($HEAD_COMMIT); prosseguindo (--allow-tag-mismatch)"
    else
        warn "a tag $TAG aponta para $TAG_COMMIT, não para HEAD ($HEAD_COMMIT)"
        warn "os artefatos em $OUT_DIR podem ter sido construídos de outro commit"
        if [ -t 0 ]; then
            printf 'continuar mesmo assim? [s/N] ' >&2
            read -r reply </dev/tty || reply=""
            case "$reply" in
                s|S|y|Y) ;;
                *) die "abortado" ;;
            esac
        else
            # No terminal to ask: refusing is the safe default, and the flag
            # exists for the deliberate case.
            die "use --allow-tag-mismatch para publicar mesmo assim"
        fi
    fi
fi

if [ -n "$(git status --porcelain)" ]; then
    warn "há mudanças não commitadas; a árvore publicada não é reproduzível a partir da tag"
fi

# --- assemble the asset list -----------------------------------------------

# Only ship artifacts that are actually present: an android-generic build has no
# disk image, and requiring every file would make this unusable for device
# profiles. SHA256SUMS goes last so it is uploaded after what it describes.
ASSETS=()
for name in \
    "kolinos-$KOLIN_VERSION-$KOLIN_CODENAME_LOWER-$KOLIN_ARCH.iso" \
    "kolinos-$KOLIN_VERSION-$KOLIN_CODENAME_LOWER-$KOLIN_ARCH.img" \
    "kolinos-$KOLIN_VERSION-$KOLIN_CODENAME_LOWER-$KOLIN_ARCH.img.xz" \
    "kolinos-$KOLIN_VERSION-$KOLIN_CODENAME_LOWER-$KOLIN_ARCH.tar.xz" \
    "kolinos-source-$KOLIN_VERSION-$KOLIN_CODENAME_LOWER.zip" \
    "METADATA.txt" \
    "SHA256SUMS"
do
    if [ -f "$OUT_DIR/$name" ]; then
        ASSETS+=("$OUT_DIR/$name")
    else
        warn "ausente, será omitido: $name"
    fi
done

[ "${#ASSETS[@]}" -gt 0 ] || die "nenhum artefato encontrado em $OUT_DIR"
log "publicando ${#ASSETS[@]} artefato(s) em $REPO como $TAG"

# --- publish ---------------------------------------------------------------

ARGS=(--repo "$REPO" --title "$TITLE" --tag "$TAG")
[ "$DRAFT" = 1 ] && ARGS+=(--draft)
[ "$PRERELEASE" = 1 ] && ARGS+=(--prerelease)
if [ -n "$NOTES" ]; then
    [ -f "$NOTES" ] || die "arquivo de notas não encontrado: $NOTES"
    ARGS+=(--notes-file "$NOTES")
else
    ARGS+=(--notes "Artefatos do KolinOS $KOLIN_VERSION ($KOLIN_CODENAME), arm64. Veja docs/PHASE8.md.")
fi

# `gh release view` succeeds only when the release already exists. Reusing the
# upload command instead of `edit` keeps this idempotent: --clobber replaces an
# asset with the same name, so re-running after a fix repairs the release rather
# than failing on the duplicate.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "release $TAG já existe; atualizando metadados e substituindo assets"
    gh release edit "$TAG" --repo "$REPO" --title "$TITLE" \
        ${NOTES:+--notes-file "$NOTES"} \
        $( [ "$DRAFT" = 1 ] && printf -- '--draft' ) \
        $( [ "$PRERELEASE" = 1 ] && printf -- '--prerelease' ) >/dev/null
    gh release upload "$TAG" --repo "$REPO" --clobber "${ASSETS[@]}"
else
    gh release create "${ARGS[@]}" "${ASSETS[@]}"
fi

log "release publicada: https://github.com/$REPO/releases/tag/$TAG"

# Report the manifest as published, so the printed hashes are the ones a
# downloader will verify against.
if [ -f "$OUT_DIR/SHA256SUMS" ]; then
    log "SHA256SUMS publicados:"
    sed 's/^/  /' "$OUT_DIR/SHA256SUMS"
fi
