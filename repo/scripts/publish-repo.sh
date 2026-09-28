#!/usr/bin/env bash
# publish-repo.sh — publish the built APT repository as a static site.
#
# Takes the tree produced by build-repo.sh (repo/public/) and publishes it so
# APT clients can fetch it over HTTPS. The default target is GitHub Pages: the
# contents go to an orphan `gh-pages` branch, which GitHub serves at
# https://<owner>.github.io/<repo>/.
#
# This script does NOT build or sign anything — run build-repo.sh first. It only
# copies bytes into a fresh branch and pushes. The public tree is generated, so
# the branch is replaced (force-push) rather than merged: there is no history
# worth keeping, and a merge would leave debs deleted upstream still served.
#
# Credentials: never hardcoded. If KOLIN_PUBLISH_TOKEN or GH_TOKEN is set and the
# remote is an https://github.com URL, the token is injected into the push URL
# for that one command. Otherwise the remote's own credentials are used.
#
# Usage: bash repo/scripts/publish-repo.sh [options]
#   --remote NAME     git remote to push to (default: origin)
#   --branch NAME     branch to publish (default: gh-pages)
#   --repo-dir DIR    built repository tree (default: repo/public)
#   --no-push         commit locally in a temp repo, do not push
#   --dry-run         show what would be published, change nothing
#   -h, --help        show this help
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../VERSION
source "$ROOT/VERSION"
CODENAME="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"

REMOTE="origin"
BRANCH="gh-pages"
REPO_DIR="$ROOT/repo/public"
DO_PUSH=1
DRY_RUN=0

log()  { printf '[publish] %s\n' "$*"; }
warn() { printf '[publish][aviso] %s\n' "$*" >&2; }
die()  { printf '[publish][erro] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --remote)    REMOTE="$2"; shift 2 ;;
        --branch)    BRANCH="$2"; shift 2 ;;
        --repo-dir)  REPO_DIR="$2"; shift 2 ;;
        --no-push)   DO_PUSH=0; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "opção desconhecida: $1" ;;
    esac
done

[ -d "$REPO_DIR/dists" ] || die "repositório não construído em $REPO_DIR (rode repo/scripts/build-repo.sh)"
[ -d "$REPO_DIR/pool" ]  || die "pool/ ausente em $REPO_DIR (rode repo/scripts/build-repo.sh)"

# A repository without a signature would be rejected by the rootfs's
# Signed-By, so refuse to publish one silently.
for f in "dists/$CODENAME/InRelease" "dists/$CODENAME/Release.gpg"; do
    if [ ! -f "$REPO_DIR/$f" ]; then
        warn "assinatura ausente: $f"
        warn "o repositório publicado seria rejeitado por Signed-By nos clientes"
        [ "$DRY_RUN" = 1 ] || die "construa um repositório assinado (repo/scripts/build-repo.sh)"
    fi
done

mapfile -t FILES < <(cd "$REPO_DIR" && find . -type f -printf '%P\n' | sort)
[ "${#FILES[@]}" -gt 0 ] || die "nada para publicar em $REPO_DIR"
TOTAL="$(du -sh "$REPO_DIR" | awk '{print $1}')"

log "origem : $REPO_DIR"
log "destino: $REMOTE:$BRANCH"
log "conteúdo: ${#FILES[@]} arquivos, $TOTAL"
for f in "${FILES[@]}"; do printf '  %s\n' "$f"; done

if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: nada foi alterado"
    exit 0
fi

# --- stage the tree in a throwaway repository ------------------------------
# Publishing must not touch the working tree or the real index, and gh-pages
# history is unrelated to main. A temp repo gives exactly that isolation.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kolinos-publish.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
PUB="$STAGE/repo"
mkdir -p "$PUB"

# Deterministic commit metadata: the published tree should not embed the wall
# clock, so the branch commit is stable across rebuilds of the same content.
EPOCH="${KOLIN_BUILD_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date -u +%s)}"
ISO_DATE="$(date -u -d "@$EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# cp -a preserves modes; the debs keep their bytes untouched.
cp -a "$REPO_DIR/." "$PUB/"

# GitHub Pages runs Jekyll unless told otherwise; Jekyll would ignore nothing
# here, but .nojekyll also documents that this is raw static content.
: > "$PUB/.nojekyll"

# A small index so a human opening the URL sees something meaningful rather
# than a directory listing or a 404.
cat > "$PUB/index.html" <<HTML
<!doctype html>
<html lang="pt-BR">
<meta charset="utf-8">
<title>KolinOS — repositório APT</title>
<style>
 body{background:#07060d;color:#f5f3ff;font:16px/1.6 system-ui,sans-serif;
      max-width:44rem;margin:12vh auto;padding:0 1.5rem}
 h1{color:#a88bff;margin-bottom:.2em} code{background:#14102a;color:#2dd4bf;
 padding:.15em .4em;border-radius:4px} a{color:#2dd4bf}
 .m{color:#a9a3c9}
</style>
<h1>KolinOS</h1>
<p class="m">Repositório APT — ${KOLIN_NAME} ${KOLIN_VERSION_CODENAME} (${KOLIN_ARCH})</p>
<p>Adicione o repositório ao seu sistema:</p>
<pre><code>Types: deb
URIs: https://${KOLIN_PAGES_HOST}/${KOLIN_PAGES_PATH}
Suites: ${CODENAME}
Components: main
Architectures: ${KOLIN_ARCH}</code></pre>
<p>Chave de assinatura: <a href="kolinos.gpg">kolinos.gpg</a> ·
Índice: <a href="dists/${CODENAME}/InRelease">InRelease</a></p>
<p class="m">Pacotes em <a href="pool/main/">pool/main/</a></p>
</html>
HTML

# The public signing key must be fetchable next to the index: that is how a
# client bootstraps trust without shipping the key in advance.
if [ -f "$ROOT/config/apt/trusted.gpg.d/kolinos.gpg" ]; then
    cp "$ROOT/config/apt/trusted.gpg.d/kolinos.gpg" "$PUB/kolinos.gpg"
fi

git -C "$PUB" init -q -b "$BRANCH"
git -C "$PUB" config user.name "KolinOS Build"
git -C "$PUB" config user.email "build@kolinos.invalid"
git -C "$PUB" add -A
GIT_AUTHOR_DATE="$ISO_DATE" GIT_COMMITTER_DATE="$ISO_DATE" \
    git -C "$PUB" commit -q -m "Repositório APT ${KOLIN_NAME} ${KOLIN_VERSION_CODENAME} (${KOLIN_ARCH})

Publicado por repo/scripts/publish-repo.sh a partir de repo/public/.
Índice: dists/${CODENAME}/main/binary-${KOLIN_ARCH}/Packages
Conteúdo gerado e assinado pelo build; nada aqui é editado à mão."

log "branch preparada: $(git -C "$PUB" rev-parse --short HEAD) (${#FILES[@]} arquivos)"

if [ "$DO_PUSH" = 0 ]; then
    # Keep the staged repo so it can be inspected or pushed by hand.
    trap - EXIT
    log "--no-push: repositório pronto em $PUB"
    exit 0
fi

# --- push ------------------------------------------------------------------
REMOTE_URL="$(git -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null || true)"
[ -n "$REMOTE_URL" ] || die "remote '$REMOTE' não existe em $ROOT"

TOKEN="${KOLIN_PUBLISH_TOKEN:-${GH_TOKEN:-}}"
if [ -n "$TOKEN" ] && case "$REMOTE_URL" in https://github.com/*) true ;; *) false ;; esac; then
    # Inject for this command only; the configured remote stays token-free.
    REMOTE_URL="https://x-access-token:${TOKEN}@${REMOTE_URL#https://}"
    log "usando token do ambiente para o push"
fi

log "enviando para $BRANCH ..."
GIT_TERMINAL_PROMPT=0 git -C "$PUB" -c credential.helper= \
    push --force "$REMOTE_URL" "HEAD:refs/heads/$BRANCH"

log "publicado: https://${KOLIN_PAGES_HOST}/${KOLIN_PAGES_PATH}/"
log "índice verificável em: https://${KOLIN_PAGES_HOST}/${KOLIN_PAGES_PATH}/dists/${CODENAME}/InRelease"
