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

A FASE 6 tem seu próprio verificador nativo (não precisa de root):
`bash scripts/host/verify-installer.sh --dest /tmp/kolinos-verify`.

## Build arm64 no sandbox (armadilhas)

Habilitar execução arm64 (binários ELF aarch64) **é possível** neste sandbox:

```sh
sudo apt-get install -y qemu-user-static binfmt-support
sudo mount -o remount,rw /proc/sys/fs/binfmt_misc   # vem montado RO
# update-binfmts não tem a entrada no database; registre direto:
sudo sh -c 'echo ":qemu-aarch64:M::\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff\xff:/usr/libexec/qemu-binfmt/aarch64-binfmt-P:OPF" > /proc/sys/fs/binfmt_misc/register'
```

Com isso, `chroot` arm64 roda de verdade (bash/apt/dpkg) e `build.sh --force`
produz o rootfs arm64 real.

O `build.sh` monta `/dev`, `/dev/pts`, `/proc`, `/sys` no rootfs (via
`kolin_mount_pseudo`). Fazer esses binds diretamente pode deixar o `/dev/pts`
do sandbox inconsistente e **matar o terminal** com
`create window failed: fork failed: No such file or directory` (até
`reset=true` falha). **Rode o build dentro de um namespace de mounts:**

```sh
sudo unshare -m --propagation private bash -c 'cd /workspace/project && bash build.sh --force'
```

Assim os binds ficam contidos no namespace e o terminal sobrevive. Builds longos
devem ir para background com log em arquivo e ser acompanhados por `tail`.

O registro no `binfmt_misc` é volátil: um resume do sandbox perde-o; reexecute
o registro antes de qualquer build/chroot arm64.

## Push para o GitHub

O `GITHUB_TOKEN` do sandbox é um token de integração **somente-leitura** para
este repositório (`Resource not accessible by integration` no git push). Para
publicar, use um PAT com permissão de escrita. Depois do push, remova o token
da URL do remote (`git remote set-url origin https://github.com/OWNER/REPO.git`).

