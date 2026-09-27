# KolinOS

KolinOS é uma distribuição Linux **baseada em Debian**, focada em **ARM64** e
pensada para rodar bem em celulares: pouca RAM, armazenamento limitado e, no
desenvolvimento, execução dentro do **Termux** usando `proot` (sem root).

- **Nome:** KolinOS
- **Codename:** Corvo
- **Versão:** 1.0.0
- **Base:** Debian 13 (trixie)
- **Arquitetura principal:** arm64 / aarch64
- **Gerenciador de pacotes:** APT/DPKG (é Debian por dentro)

> Estado atual: **Fases 1, 2, 3 e 4** concluídas. Veja [`docs/PHASES.md`](docs/PHASES.md)
> para o roadmap, [`docs/PHASE2.md`](docs/PHASE2.md) (base mínima),
> [`docs/PHASE3.md`](docs/PHASE3.md) (identidade visual) e
> [`docs/PHASE4.md`](docs/PHASE4.md) (build reproduzível), além de
> [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) para o que funciona (e o que não
> funciona) em Termux/proot/root.

---

## Início rápido

### No Termux (Android, arm64) — sem root

Pré-requisito: Termux instalado do F-Droid ou dos releases oficiais do GitHub.

```sh
pkg update && pkg install -y proot-distro
# Instalar um rootfs KolinOS já construído:
bash scripts/termux/install.sh /caminho/para/kolinos-1.0.0-corvo-arm64.tar.xz
# Entrar no sistema:
kolinos
kolinos-info
```

### Em um host Linux (Debian/Ubuntu) — para construir o rootfs

```sh
sudo apt update
sudo apt install -y debootstrap qemu-user-static binfmt-support \
                    squashfs-tools xorriso zip

sudo bash build.sh            # cria o rootfs arm64 personalizado + ISO
```

Flags úteis do `build.sh`:

| Flag | Efeito |
|---|---|
| `--slim` / `--full` | base mínima (padrão) ou completa (com man pages/docs) |
| `--only 20,30,45` | roda só alguns estágios (não recria o rootfs) |
| `--no-iso` | não gera a ISO ao final |
| `--force` | recria o rootfs do zero |
| `--include-source` | embute o código-fonte no rootfs |
| `--snapshot STAMP` | fixa as versões Debian no `snapshot.debian.org` |
| `--reproducible` | build bit-a-bit reprodutível (usa a data de `VERSION`) |

Resultado em `output/`:

| Arquivo | O que é |
|---|---|
| `kolinos-1.0.0-corvo-arm64.tar.xz` | root filesystem KolinOS (arm64) |
| `kolinos-1.0.0-corvo-arm64.iso` | ISO **carrier** (rootfs + código-fonte) — **não inicializável** |
| `kolinos-source-1.0.0-corvo.zip` | código-fonte completo do projeto |
| `SHA256SUMS`, `SOURCE-SHA256SUMS`, `METADATA.txt` | checksums e metadados do build |

Para usar no Termux, transfira o `.tar.xz` para o celular e rode
`scripts/termux/install.sh`.

---

## Estrutura do projeto

```
kolinos/
├── build.sh                 # orquestrador do build (roda os estágios em ordem)
├── VERSION                  # identidade: nome, versão, codename, base Debian
├── build/
│   ├── lib/common.sh        # funções compartilhadas (chroot, QEMU, templates)
│   └── stages/              # estágios independentes e reexecutáveis
│       ├── 00-hostcheck.sh
│       ├── 10-debootstrap.sh
│       ├── 20-apt.sh
│       ├── 30-packages.sh
│       ├── 40-identity.sh
│       ├── 50-users.sh
│       ├── 60-postinstall.sh
│       ├── 70-rootfs.sh
│       └── 80-metadata.sh
├── config/                  # arquivos que são copiados/templatizados no rootfs
│   ├── os-release.in        # template do /etc/os-release
│   ├── motd/                # motd personalizado
│   ├── branding/            # logo/textos
│   ├── skel/                # perfis de shell, prompt
│   ├── issue
│   ├── apt/                 # snippets de APT, chave de confiança
│   └── postinstall/         # hooks executados dentro do rootfs
├── packages/
│   ├── debian.list          # pacotes Debian do sistema base
│   └── custom/              # pacotes próprios (Fase 5) + debs/
├── repo/                    # repositório APT próprio (Fase 9, groundwork)
│   ├── scripts/             # build-repo.sh, make-gpg-key.sh
│   └── conf/
├── tools/                   # ferramentas KolinOS instaladas em /usr/local/bin
├── scripts/
│   ├── termux/install.sh    # instala o rootfs no Termux (proot-distro v4/v5)
│   ├── host/                # enter.sh, verify-rootfs.sh (host Linux)
│   └── artifacts/           # make-iso.sh, make-source-zip.sh
├── docs/                    # documentação detalhada
├── rootfs/                  # rootfs em construção (gerado; não versionado)
├── output/                  # artefatos finais (gerado; não versionado)
└── README.md
```

A estrutura pode evoluir, mas o princípio é: **cada estágio faz uma coisa e
pode ser reexecutado**. `build.sh --only 40,50` roda só identidade e usuários,
por exemplo.

---

## Como o build funciona

1. `build.sh` lê `VERSION` (fonte única da identidade) e valida o host.
2. `10-debootstrap.sh` cria um Debian `minbase` em `rootfs/`. Em host x86_64,
   usa `--foreign` + `qemu-aarch64-static` para montar um rootfs **arm64 real**.
3. `20-apt.sh` escreve `sources.list`, tuning de APT e o repositório KolinOS
   (desabilitado).
4. `30-packages.sh` instala o conjunto de pacotes de `packages/debian.list`.
5. `40-identity.sh` aplica nome, versão, `/etc/os-release`, motd, hostname,
   prompt e timezone.
6. `50-users.sh` cria o usuário padrão (`kolin`) com sudo.
7. `60-postinstall.sh` copia as ferramentas e roda os hooks de pós-instalação.
8. `70-rootfs.sh` limpa e empacota o rootfs em `.tar.xz`.
9. `80-metadata.sh` grava checksums e metadados.
10. `build.sh` gera a ISO carrier com `xorriso`.

Opções úteis: `--arch`, `--suite`, `--mirror`, `--snapshot`, `--reproducible`,
`--epoch`, `--rootfs`, `--output`, `--force`, `--only`, `--no-iso`,
`--keep-qemu`, `--include-source`.

---

## Documentação

- [`docs/PHASES.md`](docs/PHASES.md) — as 10 fases, com o que já existe.
- [`docs/PHASE2.md`](docs/PHASE2.md) — a base mínima (modo slim, locale, higiene).
- [`docs/PHASE3.md`](docs/PHASE3.md) — identidade visual, paleta e ferramentas.
- [`docs/PHASE4.md`](docs/PHASE4.md) — build reproduzível (snapshot, epoch, teste).
- [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) — Termux vs proot vs root vs kernel.
- [`docs/BUILD.md`](docs/BUILD.md) — construir, testar e entrar no sistema.

---

## Licença

O sistema de build do KolinOS é distribuído sob os termos em [`LICENSE`](LICENSE).
O rootfs contém pacotes Debian, distribuídos sob suas próprias licenças
(veja `/usr/share/doc/*/copyright` dentro da imagem).
