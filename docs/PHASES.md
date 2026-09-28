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

## FASE 3 — Personalização do sistema ✅

**Objetivo:** o sistema se identifica como KolinOS, não como Debian — no texto,
na cor e nas ferramentas. Detalhes em `docs/PHASE3.md`.

O que existe (`40-identity.sh`):

- `/etc/os-release` e `/usr/lib/os-release` personalizados (`ID=kolinos`,
  `ID_LIKE=debian`), motd com o logotipo do corvo, `/etc/issue` e hostname.
- **Paleta de marca** como fonte única em `VERSION`
  (`KOLIN_COLOR_PRIMARY/ACCENT/...`), renderizada em `/etc/kolinos/colors.sh`
  (só emite escapes quando é um terminal).
- Prompt colorido usando os tokens de cor, via `/etc/profile.d/kolinos.sh`.
- `kolinos-info` (estilo neofetch: logo + SO, base, arquitetura, kernel,
  hostname, usuário, shell, pacotes, memória, uptime) e `kolinos-version`.
- Usuário padrão `kolin` com sudo (`50-users.sh`) e hooks (`config/postinstall/`).
- O verificador garante que **nenhum placeholder `@KOLIN_*@` ficou pendente**.

Pendente (FASE 7, gráfica): logo/wallpaper em imagem, tema de desktop, ícones.

---

## FASE 4 — Build reproduzível ✅

**Objetivo:** o mesmo commit produz o mesmo artefato, byte a byte.

O que existe:

- Snapshot Debian opcional (`--snapshot` / `--reproducible`): espelhos viram
  `snapshot.debian.org` no carimbo escolhido, então as versões de pacote não
  mudam entre builds.
- Epoch fixo (`KOLIN_BUILD_EPOCH`, padrão = data do commit `HEAD`) aplicado em
  todos os mtimes, no `tar`, no ISO, no `METADATA.txt` e no `MANIFEST`.
- Empacotamento determinístico: ordem `LC_ALL=C`, `--owner/--group 0`,
  formato `pax` sem `atime`/`ctime` (que faziam o hash mudar a cada leitura).
- ISO reprodutível (`--set_all_file_dates`) e ZIP de fontes com mtime fixo.
- Teste de aceitação `scripts/host/verify-reproducible.sh`, que constrói duas
  vezes e compara o SHA-256.
- `path-exclude` para arquivos-skeleton do dpkg (`/etc/default/rcS`).

Detalhes: `docs/PHASE4.md`.

Fora de escopo (fica para depois):

- Build em container/CI (GitHub Actions com cache).

---

## FASE 5 — Pacotes próprios ✅

**Objetivo:** criar e empacotar software KolinOS como `.deb`. Detalhes em
`docs/PHASE5.md`.

O que existe:

- Receitas em `packages/custom/`: `kolinos-base` (metapacote),
  `kolinos-tools` (ferramentas em `/usr/bin`) e `kolinos-branding` (identidade
  visual em `/etc/kolinos/branding`).
- `scripts/host/build-deb.sh`: empacota com apenas `dpkg-deb` (sem
  `debhelper`/`sbuild`), gera `md5sums`/`Installed-Size` e é **reprodutível**
  (`SOURCE_DATE_EPOCH` + `--root-owner-group`).
- Novo estágio `35-packages.sh`: constrói os `.deb`, monta um repositório APT
  local e instala via `apt-get install kolinos-base` — dependências resolvidas
  de verdade pelo APT, sem rede (`file://`).
- `tools/apt-kolinos`: liga/desliga o repositório KolinOS no sistema instalado.
- `repo/scripts/build-repo.sh` endurecido: determinístico, multi-arquitetura e
  com `Date` em RFC 1123 no `Release`.
- O antigo caminho manual (`tools/` copiados em `60-postinstall.sh`) foi
  removido: agora os arquivos pertencem ao dpkg.
- `--no-custom-debs` permite pular a fase (builds mínimos/sem rede).

Como testar: `sudo bash build.sh --only 35` e depois
`sudo bash scripts/host/verify-rootfs.sh` (bloco "Pacotes próprios").

Fora de escopo (fica para depois):

- Pacotes com código compilado (aí `debhelper`/`sbuild`) e `kolinos-desktop`
  (FASE 7).
- Publicação e assinatura do repositório (FASE 9).

---

## FASE 6 — Sistema de instalação ✅

**Objetivo:** instalar o KolinOS com um comando.

O que existe:

- `install/kolinos-install.sh`: front-end único que detecta o ambiente e escolhe
  o backend.
- `install/targets/proot.sh`: instala o rootfs no Termux via `proot-distro`
  (v5 usa o arquivo local; v4 usa plugin gerado automaticamente). Sem root.
- `install/targets/dir.sh`: implanta o rootfs em um diretório de um host Linux
  (com root) e finaliza com o first boot; entra por `chroot`.
- `install/targets/disk.sh`: escreve o rootfs num dispositivo de bloco
  (groundwork da Fase 10, com travas destrutivas).
- `tools/kolinos-firstboot` (pacote `kolinos-tools`): setup idempotente que roda
  uma vez — machine-id, resolv.conf de runtime, repositório APT e resumo.
- `config/firstboot/kolinos-firstboot.sh`: gancho de login que dispara o first
  boot em mídias escritas sem o instalador.
- `scripts/termux/install.sh` agora é um shim que encaminha para o front-end.
- `scripts/host/verify-installer.sh`: verificador do instalador, roda nativo.
- `scripts/host/enter.sh` para chroot no host.

Falta ainda:

- Instalador para hardware real bootável (kernel + bootloader — Fase 10).

Detalhes em [`docs/PHASE6.md`](PHASE6.md).

---

## FASE 7 — Interface gráfica: tema "Corvo Glass" ✅

**Objetivo:** ambiente gráfico leve e bonito, adequado a celular, com identidade
própria (glassmorphism). Detalhes em [`docs/PHASE7.md`](PHASE7.md).

O que existe:

- Stack leve: `openbox` (WM) + `picom` (compositor, o que dá o vidro) +
  `tint2` (painel) + `rofi` (launcher) + `xterm`/`foot` (terminal),
  com `feh` para o wallpaper. Sem GNOME/KDE/XFCE.
- Tema próprio "Corvo Glass": GTK 3 (`gtk.css`), GTK 2 (`gtkrc`), tema de
  openbox, `picom.conf` (blur/glass), `kolinos.tint2rc`, `kolinos.rasi`,
  `Xresources`/`foot.ini`. Paleta em `config/branding/glass-palette.txt`,
  tokens em `VERSION` (`KOLIN_GLASS_*`).
- Assets SVG (emblema, wallpapers mobile 1080×2400 e desktop 1920×1080),
  renderizados por `scripts/artifacts/render-assets.sh` (`rsvg-convert`).
- Pacotes `kolinos-desktop` (metapacote + greeter do lightdm) e
  `kolinos-theme` (arquivos de tema). `kolinos-base` só os sugere.
- Comandos `kolinos-session`, `kolinos-terminal`, `kolinos-wallpaper`,
  `kolinos-launcher` (`kolinos-tools`).
- Build opt-in: `sudo bash build.sh --with-desktop`; estágio `65-desktop.sh`
  valida e aplica preferências por usuário.
- Sem instalar o desktop: `apt-kolinos enable && sudo apt-get install kolinos-desktop`.
- Testes: `scripts/host/preview-theme.sh` (captura o tema em Xvfb, com blur) e
  `scripts/host/verify-desktop.sh` (checagens nativas dos `.deb`, configs e ausência de conflitos com pacotes Debian).

Limitações (leia `docs/PHASE7.md` §2): GUI exige um **servidor X** — no Termux
isso é Termux:X11 (`DISPLAY=:0 kolinos-session`); sem X não há janelas. Nada
aqui depende de root; `lightdm` só faz sentido em hardware real.

---

## FASE 8 — Imagens distribuíveis ✅

**Objetivo:** produzir imagens prontas para distribuir — e que realmente
inicializem. Detalhes completos em `docs/PHASE8.md`.

O que existe:

- Rootfs `.tar.xz` versionado e com checksum (`output/`) — o artefato para
  Termux/`proot-distro`.
- **ISO carrier** gerada automaticamente (`scripts/artifacts/make-iso.sh`):
  contém o rootfs, o código-fonte e o instalador. **Não é inicializável.**
- **Imagem de disco inicializável** (`build/stages/85-image.sh`, `--with-image`):
  GPT com ESP FAT32 (GRUB EFI + kernel + initrd, menu com a marca) e partição
  root ext4. Mais `.img.xz` comprimida. Montada **sem `loop device`**, usando
  `mke2fs -d`, `parted` e mtools.
- **Verificação de boot real** (`scripts/host/qemu-boot.sh`): boota o rootfs via
  virtio-9p ou a imagem via firmware UEFI (EDK2/AAVMF) e espera o sistema chegar
  ao userspace. Boot confirmado até `kolinos login:`.

Corrigido nesta fase (afetava todos os artefatos):

- `/dev/null` era arquivo comum no archive; agora é saneado (`kolin_fix_dev`).
- Donos errados: `tar --owner=0` apagava contas reais (`/home/kolin` saía
  `0/0`), e arquivos criados por redirecionamento herdavam o uid do host
  (10001). Agora `kolin_normalize_owners` mapeia só ids sem conta.

Falta ainda:

- ISO **bootável** (hoje é carrier de dados; o `.img` é que inicializa).
- Instalador gráfico.
- Suporte a bootloader de celular (é FASE 10, não esta).

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
