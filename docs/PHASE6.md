# FASE 6 — Sistema de instalação

**Objetivo:** instalar o KolinOS com um comando, sem esconder o que cada
plataforma pode ou não fazer.

Esta fase reúne as formas de colocar o KolinOS em um dispositivo e **finaliza a
instalação dentro do próprio sistema** (first boot). O que ela **não** faz — e
não pode fazer sem kernel próprio e bootloader — é produzir uma imagem
inicializável. Isso é a Fase 10 (veja `docs/LIMITATIONS.md`).

## 1. Um comando, três backends

O ponto de entrada é `install/kolinos-install.sh`. Ele detecta onde está rodando
e escolhe o backend:

| Ambiente | Backend | Precisa de root? | Resultado |
|---|---|---|---|
| Termux / Android | `install/targets/proot.sh` | **não** | container `proot-distro` |
| Linux com root | `install/targets/dir.sh` | sim | rootfs em um diretório (chroot) |
| Linux com root | `install/targets/disk.sh` | sim | rootfs escrito num dispositivo de bloco |

```
install/
├── kolinos-install.sh      # front-end: detecta o ambiente e despacha
├── lib/common.sh           # detecção de ambiente, checksum, travas de segurança
└── targets/
    ├── proot.sh            # Termux / Android (sem root)
    ├── dir.sh              # host Linux: implantar em um diretório
    └── disk.sh             # host Linux: escrever num dispositivo (Fase 10)
```

### Termux (Android, arm64) — o caminho de hoje

```sh
pkg install proot-distro
bash install/kolinos-install.sh rootfs/kolinos-1.0.0-corvo-arm64.tar.xz
```

Ou, pelo front-end automático:

```sh
bash install/kolinos-install.sh
```

Isso instala o container, cria o atalho `kolinos` (em `$PREFIX/bin`), roda o
first boot e valida a identidade.

### Host Linux com root — implantar num diretório

```sh
sudo bash install/kolinos-install.sh --target dir --dest /opt/kolinos \
     rootfs/kolinos-1.0.0-corvo-arm64.tar.xz
sudo chroot /opt/kolinos /bin/bash -l
```

O destino precisa estar **vazio**; o instalador recusa `/`, `/usr`, `/etc`,
`/var`, `/home`, `/root` e `/boot`.

### Host Linux com root — escrever num dispositivo (Fase 10)

```sh
sudo bash install/kolinos-install.sh --target disk --device /dev/sdX1 \
     --format ext4 --force rootfs/kolinos-1.0.0-corvo-arm64.tar.xz
```

Exige `--force` **e** confirmação interativa, recusa um dispositivo montado e
recusa o dispositivo que contém o sistema em execução. O meio resultante **não é
inicializável**: não há kernel nem bootloader.

## 2. First boot

O first boot é o que transforma um rootfs genérico em uma instalação específica
daquela máquina. Fica em `tools/kolinos-firstboot`, dentro do pacote
`kolinos-tools`, e é idempotente (marcador `/etc/kolinos/firstboot.done`,
`--force` para repetir).

O que ele faz, sem rede:

- **machine-id**: o rootfs é construído com `/etc/machine-id` **vazio** de
  propósito — esse é o sinal que o systemd usa para "ainda não inicializado".
  Assim cada instalação recebe o seu próprio id em vez de todas compartilharem
  um. A geração é robusta: tenta `systemd-machine-id-setup`, depois
  `dbus-uuidgen`, depois `/proc/sys/kernel/random/uuid`, depois `/dev/urandom`,
  e valida o resultado (32 hex).
- **resolv.conf**: só cria um de runtime se o sistema não tiver nenhum; o
  container (proot-distro) normalmente fornece o dele.
- **repositório APT**: deixa `kolinos.sources` presente e inativo (Fase 9).
- **resumo**: imprime usuário padrão, senha e o comando `apt-kolinos`.

O instalador roda o first boot logo após a implantação. Para mídias escritas por
outros meios (`dd`, ferramentas de imagem), um gancho em
`/etc/profile.d/kolinos-firstboot.sh` o executa no primeiro login interativo.

## 3. Limites por plataforma (seja honesto)

- **Termux/proot (sem root):** funciona. O proot implementa as syscalls em espaço
  de usuário, então um rootfs de outra arquitetura roda sob QEMU. É a única forma
  de "rodar" o KolinOS num celular hoje.
- **Android com root:** ainda **não** é uma instalação de verdade. Android não
  permite inicializar outro kernel Linux; continua sendo proot-family.
- **`--target dir`:** produz um root de verdade, mas sem kernel/bootloader; entra
  por `chroot` num host Linux.
- **`--target disk`:** escreve o rootfs, mas o meio **não inicializa sozinho**.
- **Bootável:** exige kernel próprio + bootloader (Fase 10); em Android, exige
  bootloader desbloqueado. Nada aqui contorna isso.

## 4. Como testar nesta fase

```sh
# 1. Verificações do instalador (sem root, sem tocar no sistema):
bash scripts/host/verify-installer.sh --dest /tmp/kolinos-verify
```

Checa existência/`--help` dos backends, rejeição de `--target` inválido, as
travas destrutivas (destino não vazio, caminho perigoso, `--device`/`--dest`
obrigatórios) e o verificador de checksum (válido passa, inválido falha).

Em um host Linux com root, o ciclo completo com um rootfs de teste:

```sh
# build de teste amd64 (rápido; valida a mecânica, não o arm64)
sudo bash build.sh --arch amd64 --rootfs /tmp/k/rootfs --output /tmp/k/out --no-iso --force

# as checagens da Fase 6 no rootfs
sudo env KOLIN_ARCH=amd64 DEB_ARCH=amd64 bash scripts/host/verify-rootfs.sh /tmp/k/rootfs

# instalação de verdade (extrai + first boot)
sudo KOLIN_ASSUME_YES=1 bash install/kolinos-install.sh --target dir \
     --dest /tmp/k/deploy /tmp/k/out/kolinos-1.0.0-corvo-amd64.tar.xz
sudo grep -qE '^[0-9a-f]{32}$' /tmp/k/deploy/etc/machine-id && echo "machine-id OK"
```

Resultado esperado: `machine-id` gerado, `/etc/kolinos/firstboot.done` presente e
`PRETTY_NAME` = `KolinOS 1.0.0 (Corvo)`.

## 5. O que ficou pronto / o que falta

Pronto: front-end com detecção de ambiente, três backends, first boot
idempotente, gancho de login, instalação de teste em diretório, verificador.

Falta (e pertence a outras fases):

- tornar o meio inicializável: kernel + bootloader (Fase 10);
- particionamento assistido e seleção de bootloader (Fase 10);
- integrar os pacotes próprios ao primeiro boot quando o repositório remoto
  existir (Fase 9).
