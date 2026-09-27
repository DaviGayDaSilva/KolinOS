# FASE 3 — Personalização do sistema

Objetivo: uma vez que a base mínima está pronta (FASE 2), fazer o sistema se
**identificar como KolinOS** em todos os pontos que o usuário vê — arquivos de
identidade, banner de login, prompt e ferramentas — sem depender de interface
gráfica (isso é a FASE 7).

## Fonte única da identidade

Tudo nasce de dois arquivos versionados:

- **`VERSION`** — nome, versão, codename, hostname, usuário, locale, timezone e
  a **paleta de cores** (`KOLIN_COLOR_*`, códigos SGR de 256 cores).
- **`config/`** — templates com placeholders `@KOLIN_*@` que o build renderiza.

Nenhum valor de identidade é escrito à mão dentro de um estágio. Trocar a cor da
marca ou o nome é editar `VERSION` e reconstruir.

## O que cada arquivo se torna no sistema

| Origem | Destino no rootfs |
|---|---|
| `config/os-release.in` | `/etc/os-release` e `/usr/lib/os-release` |
| `config/motd/00-header` | `/etc/motd` (banner do corvo) |
| `config/issue` | `/etc/issue` e `/etc/issue.net` |
| `config/branding/logo.txt` | `/etc/kolinos/branding/logo.txt` |
| `config/branding/logo-small.txt` | `/etc/kolinos/branding/logo-small.txt` |
| `config/branding/palette.txt` | `/etc/kolinos/branding/palette.txt` |
| `config/branding/colors.sh.in` | `/etc/kolinos/colors.sh` |
| `config/skel/kolinos.sh` | `/etc/profile.d/kolinos.sh` |
| `tools/kolinos-info`, `tools/kolinos-version` | `/usr/local/bin/*` |

## Paleta de marca

A paleta é definida uma vez em `VERSION`:

| Token | Cor | Uso |
|---|---|---|
| `PRIMARY` | 99 (roxo/índigo) | marca, título, prompt |
| `ACCENT` | 44 (ciano) | destaques e valores |
| `MUTED` | 245 (cinza) | rótulos, texto secundário |
| `OK` / `WARN` / `ERR` | 76 / 214 / 203 | mensagens de estado |

`/etc/kolinos/colors.sh` converte os códigos em escapes ANSI **somente quando a
saída é um terminal**. Isso significa que `kolinos-info > arquivo.txt` sai limpo,
sem lixo de escape — importante em scripts e logs.

O `ANSI_COLOR` do `/etc/os-release` usa o RGB equivalente ao PRIMARY
(`#785AC8`), que é o que o systemd/`/etc/issue` interpreta.

## Ferramentas

- **`kolinos-info`** — estilo `neofetch`. Mostra o logotipo do corvo na cor da
  marca e uma tabela com SO, base Debian, `ID`/`ID_LIKE`, arquitetura, kernel,
  hostname, usuário, shell, contagem de pacotes, memória, uptime e data do build.
  - Campos baseados em `/proc` (memória, uptime) aparecem only quando existem,
    o que mantém a ferramenta útil também dentro de proot.
  - O **hostname** é lido de `/etc/hostname`, não do comando `hostname`: dentro
    de proot/chroot o kernel é o do Android, e `hostname` mostraria o nome do
    aparelho em vez de `kolinos`.
- **`kolinos-version`** — string curta `KolinOS 1.0.0 (corvo)`.

## Prompt

`/etc/profile.d/kolinos.sh` define um `PS1` colorido com os tokens da paleta e
é carregado por `/etc/skel/.bashrc` e `/root/.bashrc`. O banner (`/etc/motd`) é
exibido uma única vez por login interativo (guarda `KOLINOS_BANNER_SHOWN`).

## Como testar

Depois de reconstruir (`sudo bash build.sh --only 40,60,70,80 --no-iso`):

```bash
sudo bash scripts/host/verify-rootfs.sh        # inclui o bloco "Identidade visual"
sudo bash scripts/host/enter.sh                # vê o banner e o prompt reais
kolinos-info
```

O verificador confere paleta, logo, tokens de cor, o `kolinos-info` completo e
que **nenhum placeholder `@KOLIN_*@` sobrou** em `/etc`, `/usr/local/bin` ou
`/usr/lib/os-release`.

## Limites

- Sem interface gráfica nesta fase: não há logo em imagem, fonte ou wallpaper.
  Isso é FASE 7, e depende de um ambiente X/terminal gráfico.
- Dentro do proot o `hostname` real do kernel não muda; a identidade "kolinos"
  é do userspace (`/etc/hostname`, `os-release`, prompt, banner). Mudar o
  hostname do sistema operacional de verdade exige root/kernel — FASE 10.
