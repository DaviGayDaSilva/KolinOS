# FASE 2 — RootFS Debian mínimo

Objetivo: partindo da FASE 1, ter um Debian **arm64** mínimo, enxuto,
consistente e que já se identifica como KolinOS — pronto para ser empacotado e
instalado no Termux (`proot-distro`) ou aberto com `chroot` no host.

## Pipeline da fase

Cada estágio é descoberto automaticamente por `build/stages/NN-*.sh` (ordem
lexical) e é reexecutável de forma independente via `--only`.

| Estágio | Arquivo | O que faz nesta fase |
|---|---|---|
| 00 | `00-hostcheck.sh` | confere `debootstrap`, `chroot`, `tar`, QEMU |
| 10 | `10-debootstrap.sh` | aplica o cfg slim e cria o rootfs (minbase) |
| 20 | `20-apt.sh` | renderiza `sources.list`, tuning de APT, atualiza índices |
| 30 | `30-packages.sh` | instala `packages/debian.list` |
| 45 | `45-system.sh` | locale, `fstab`, `machine-id`, `resolv.conf` |
| 40 | `40-identity.sh` | identidade/hostname/motd (FASE 3 começa aqui) |
| 50 | `50-users.sh` | usuário `kolin` e sudo |
| 60 | `60-postinstall.sh` | ferramentas e hooks |
| 70 | `70-rootfs.sh` | limpeza final e empacotamento `.tar.xz` |
| 80 | `80-metadata.sh` | checksums e `METADATA.txt` |

## Base mínima (o que a torna "mínima")

`debootstrap --variant=minbase` traz apenas `required` + `apt` + `coreutils`.
Sobre isso, a FASE 2 aplica:

- **Modo slim (padrão).** `config/dpkg/99kolinos-slim.conf` é copiado para
  `/etc/dpkg/dpkg.cfg.d/` **antes do segundo estágio** do debootstrap, de modo
  que *todo* pacote desempacotado depois já perde:
  - `/usr/share/man/*`, `/usr/share/info/*`
  - `/usr/share/doc/*`, **exceto** `*/copyright` (exigência legal)
  - `/usr/share/locale/*`, exceto `C` e `locale.alias`
  - `/usr/share/lintian/*`, `/usr/share/bug/*`
  Use `--full` para desativar e manter tudo.
- **APT enxuto.** `config/apt/kolinos-apt.conf`:
  ```
  APT::Install-Recommends "false";
  APT::Install-Suggests  "false";
  APT::Keep-Downloaded-Packages "false";
  Acquire::Languages "none";
  Acquire::Retries "3";
  ```
- **Locale.** `KOLIN_LOCALE=C.UTF-8` já vem compilado no glibc — não precisa de
  `locale-gen`. Se você mudar para outro locale (ex.: `pt_BR.UTF-8`), o estágio
  45 gera automaticamente via `locale-gen` (existe em `/usr/sbin/locale-gen`;
  `locales` está em `packages/debian.list`).
- **Estado limpo.** O estágio 70 zera `machine-id`, `resolv.conf` (nunca o do
  host), histórico de shell, logs e caches, e remove as chaves SSH de host.

## Como construir e testar

No host (Debian/Ubuntu, com root):

```bash
sudo bash build.sh                 # slim, arm64, trixie
sudo bash scripts/host/verify-rootfs.sh
sudo bash scripts/host/enter.sh    # chroot interativo
```

Retomar só alguns estágios (não recria o rootfs):

```bash
sudo bash build.sh --only 20,30,45,70,80 --no-iso
```

Build "cheio" (com man pages e docs), útil para comparar tamanhos:

```bash
sudo bash build.sh --full --no-iso
```

## Limites honestos (o que NÃO é possível sem root / em proot)

- `chroot` e `debootstrap` **exigem root** — no Termux isso não existe; use
  `proot-distro` (FASE 6), que emula em espaço de usuário.
- `mount --bind`/`proc` (usados por `kolin_mount_pseudo`) também **exigem
  root**. Em proot isso é responsabilidade do próprio proot.
- Sem um kernel próprio, o "kernel" visto no rootfs é o do Android/host. Isso é
  esperado e só muda na FASE 10.
- `arm64` é a arquitetura-alvo. Num host x86_64 o build cross usa
  `qemu-aarch64-static` (lento, mas correto).

## Critério de aceite da fase

1. `build.sh` termina sem erro e produz `output/kolinos-*-arm64.tar.xz`.
2. `verify-rootfs.sh` passa 100% (incluindo o bloco "Base mínima (FASE 2)").
3. `dpkg --print-architecture` = `arm64` e `. /etc/os-release` mostra `ID=kolinos`.
4. O arquivo contém `etc/os-release`, `usr/local/bin/kolinos-info` e
   `etc/kolinos/version`, e **não** contém `usr/bin/qemu-aarch64-static`.

## Espaço

O modo slim leva o rootfs de ~267 MB para ~199 MB e o `.tar.xz` de ~57 MB para
~34 MB — adequado a celular. O que se ganha:

| Item | Antes | Depois |
|---|---|---|
| `usr/share/man` | 9 MB | ~0 |
| `usr/share/locale` | 55 MB | ~0 (só `C` e `locale.alias`) |
| `usr/share/i18n` | 17 MB | ~0 (só útil p/ gerar locale) |
| `usr/share/doc` | 17 MB | 9 MB (só `copyright`) |

> Nota técnica: o primeiro estágio do `debootstrap` extrai os pacotes base com
> `dpkg-deb` direto, **ignorando** `dpkg.cfg.d`. Por isso o cfg slim pega os
> pacotes instalados depois (estágio 30 em diante) e o estágio 45 faz uma
> varredura explícita (`kolin_slim_sweep`) para os que vieram do bootstrap.
