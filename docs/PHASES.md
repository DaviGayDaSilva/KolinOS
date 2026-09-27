# KolinOS — Roadmap de fases

O projeto é construído em fases **sequenciais**. Cada fase só avança quando a
anterior está verificável. Nada aqui depende de root quando não precisa.

Legenda de estado: ✅ implementado · 🟡 base pronta / parcial · ⬜ não iniciado

---

## FASE 1 — Ambiente de desenvolvimento ✅

**Objetivo:** ter um ambiente onde seja possível desenvolver, construir e testar
o KolinOS sem depender de um PC dedicado.

O que existe:

- Repositório Git com estrutura organizada e identidade em `VERSION`.
- Build executável em qualquer Debian/Ubuntu com `debootstrap`.
- **Build cross-arch:** em um host x86_64 é possível gerar um rootfs **arm64
  real**, via `debootstrap --foreign` + `qemu-aarch64-static`.
- Caminho de teste principal no celular: **Termux + proot-distro** (sem root).
- Scripts de verificação (`scripts/host/verify-rootfs.sh`) e de entrada
  (`scripts/host/enter.sh`).

Como testar: `sudo bash build.sh` e depois
`sudo bash scripts/host/verify-rootfs.sh`.

---

## FASE 2 — RootFS Debian mínimo ✅

**Objetivo:** um Debian arm64 mínimo, enxuto e consistente, que já se identifica
como KolinOS. Detalhes completos em `docs/PHASE2.md`.

O que existe (`10-debootstrap.sh` + `20-apt.sh` + `30-packages.sh` +
`45-system.sh`):

- `debootstrap --variant=minbase --arch=arm64` na suíte `trixie`.
- `sources.list` gerado de `config/apt/sources.list.in` e tuning de APT em
  `config/apt/kolinos-apt.conf` (sem recommends, sem traduções, `Retries 3`).
- **Modo slim** (padrão, `--full` desativa): `config/dpkg/99kolinos-slim.conf`
  descarta man/info/locale/lintian/bug no unpack, preservando `copyright`.
- Conjunto base enxuto em `packages/debian.list`, escolhido para caber em
  celular.
- Novo estágio `45-system.sh`: normaliza locale, `fstab`, `machine-id` e
  `resolv.conf` (nunca vaza o host).
- Estágios descobertos automaticamente por `NN-*.sh` — nenhuma lista fixa.

Como testar: `sudo bash build.sh && sudo bash scripts/host/verify-rootfs.sh`.

---

## FASE 3 — Personalização do sistema 🟡

**Objetivo:** o sistema se identifica como KolinOS, não como Debian.

O que existe (`40-identity.sh`):

- `/etc/os-release` e `/usr/lib/os-release` personalizados (template
  `config/os-release.in`).
- Motd, `/etc/issue`, hostname, prompt colorido e timezone.
- Ferramentas `kolinos-info` e `kolinos-version` em `/usr/local/bin`.
- Usuário padrão `kolin` com sudo (`50-users.sh`).
- Hooks de pós-instalação (`config/postinstall/`).

Falta ainda (próximas iterações desta fase):

- Ícone/logo gráfico definitivo.
- Tema visual (fontes, cores) e wallpaper.
- `neofetch`-like próprio mais rico.

---

## FASE 4 — Build reproduzível 🟡

**Objetivo:** o mesmo comando produz o mesmo resultado, de forma consistente.

O que existe:

- Build modular por estágios independentes e reexecutáveis.
- Identidade centralizada em `VERSION` (fonte única).
- Metadados e checksums gerados automaticamente (`80-metadata.sh`).
- `.gitignore` mantém `rootfs/` e `output/` fora do controle de versão.

Falta ainda:

- Fixar versões (snapshot Debian via `snapshot.debian.org`) para builds
  bit-a-bit reprodutíveis.
- Build em container/CI (GitHub Actions com cache).

---

## FASE 5 — Pacotes próprios ⬜

**Objetivo:** criar e empacotar software KolinOS como `.deb`.

Planejado:

- `packages/custom/` com receitas de build (`dpkg-buildpackage`).
- Pacotes `kolinos-base`, `kolinos-tools`, `kolinos-branding`.
- Uso de `debuild`/`sbuild` no host, sem precisar de hardware ARM.

Estado atual: a pasta e a integração com o repositório já existem; as receitas
serão adicionadas nesta fase.

---

## FASE 6 — Sistema de instalação 🟡

**Objetivo:** instalar o KolinOS com um comando.

O que existe:

- `scripts/termux/install.sh`: instala o rootfs no Termux via `proot-distro`
  (v5 usa o arquivo local; v4 usa plugin gerado automaticamente).
- Cria o atalho `kolinos` no Termux e valida a instalação ao final.
- `scripts/host/enter.sh` para chroot no host.

Falta ainda:

- Instalador para hardware real (a partir da Fase 10).

---

## FASE 7 — Interface gráfica ⬜

**Objetivo:** ambiente gráfico leve, adequado a celular.

Planejado (nesta ordem, do mais leve ao mais completo):

1. Window manager leve (ex.: `openbox`) + terminal (ex.: `foot`/`xterm`).
2. Gerenciador de login (`lightdm`) se necessário.
3. Desktop leve (ex.: `xfce4`).
4. Tema, ícones e wallpapers próprios.

> Importante: **não** instalar ambiente gráfico pesado na Fase 1–6. Rodar GUI
> dentro do Termux exige `termux-x11`/VNC — isso é tratado nesta fase, não antes.

---

## FASE 8 — Imagens distribuíveis 🟡

**Objetivo:** produzir imagens prontas para distribuir.

O que existe:

- Rootfs `.tar.xz` versionado e com checksum (`output/`).
- **ISO carrier** gerada automaticamente (`scripts/artifacts/make-iso.sh`):
  contém o rootfs, o código-fonte e o instalador. **Não é inicializável.**

Falta ainda:

- ISO **bootável** com kernel + bootloader (depende da Fase 10).
- Imagem de disco (`.img`) para placas/armazenamento.

---

## FASE 9 — Repositório próprio 🟡

**Objetivo:** um repositório APT assinado para os pacotes KolinOS.

O que existe (`repo/`):

- `scripts/build-repo.sh` gera `pool/` + `dists/<codename>/main/binary-arm64/`
  com `Packages`, `Packages.gz` e `Release`.
- `scripts/make-gpg-key.sh` cria a chave Ed25519 de assinatura.
- O rootfs já traz `/etc/apt/sources.list.d/kolinos.sources.disabled` e o
  snippet de confiança em `config/apt/trusted.gpg.d/`.

Falta ainda:

- Publicação (GitHub Pages / servidor próprio) e ativação por padrão.
- Rotação de chaves e política de assinatura.

---

## FASE 10 — Suporte a hardware real ⬜

**Objetivo:** o KolinOS rodar em um aparelho, não só em container.

Isto é o que exige **muito mais** do que as fases anteriores:

- **Kernel Linux próprio** compilado para o hardware (ou um kernel genérico
  com device tree adequado).
- **Bootloader**: no Android, `fastboot`/`aboot` com bootloader desbloqueado;
  alternativas: dispositivos com suporte a mainline, `postmarketOS`, ou placas
  SBC (Raspberry Pi, etc.).
- **Drivers**: GPU, modem, Wi-Fi, touch — o maior esforço de portabilidade.
- Instalador em `.img` para cartão/partição e recuperação via `fastboot`.

> Nada nesta fase é possível apenas com Termux ou proot. É um projeto de
> portabilidade de kernel. Veja `docs/LIMITATIONS.md`.
