# KolinOS — guia para agentes

Distribuição Linux baseada em Debian 13 (trixie), arm64, pensada para rodar em
Termux/proot durante o desenvolvimento. Identidade em `VERSION` (fonte única).

## Build

```sh
sudo bash build.sh                 # rootfs + ISO carrier
sudo bash build.sh --reproducible  # snapshot Debian fixo + epoch fixo
sudo bash scripts/host/verify-rootfs.sh   # sanity-check do rootfs
sudo bash scripts/host/verify-reproducible.sh --snapshot 20250901T000000Z
```

Cross-build arm64 em host x86_64 usa `debootstrap` + `qemu-aarch64-static`.
O rootfs fica em `rootfs/`; artefatos em `output/` (ambos no `.gitignore`).

## Padrões do projeto

- Estágios em `build/stages/NN-*.sh`, cada um com `stage_main()` e reexecutável
  via `build.sh --only NN`. Helpers em `build/lib/common.sh`.
- `render_template` substitui `@KOLIN_*@` a partir do ambiente exportado.
- Identidade: nunca escreva nome/versão hardcoded; use `KOLIN_*` de `VERSION`.

## Reprodutibilidade (FASE 4) — armadilhas já resolvidas

Fontes de não-determinismo que **já** têm tratamento; não reintroduza:

- `chpasswd` gera salt aleatório no `/etc/shadow` → use
  `openssl passwd -6 -salt kolinos` + `usermod -p`.
- `var/cache/ldconfig/aux-cache` grava inodes → removido no estágio 70.
- `tar` GNU grava `atime`/`ctime` → formato `pax`, `delete=atime,delete=ctime`,
  `--owner=0 --group=0 --numeric-owner`, ordem `LC_ALL=C`.
- `date` corrente em qualquer artefato → use `kolin_iso_utc "$KOLIN_BUILD_EPOCH"`.
- Snapshot Debian tem `Valid-Until` no passado → `[check-valid-until=no]` nos
  `sources.list` (escopo por repositório; a opção global por host **não** funciona).
- Um `git commit` novo muda o epoch: enquanto a árvore estiver suja o hash do
  build se mantém, mas o `git commit` final precisa ser feito para congelá-lo.

Ver `docs/PHASE4.md` para a lista completa.

## Testes

Não há suíte unitária. A verificação é por inspeção do rootfs com
`scripts/host/verify-rootfs.sh` (precisa de root + qemu-user-static). Builds
completos levam ~5 min.
