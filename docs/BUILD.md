# KolinOS — Construindo e testando

## 1. Construir no host Linux (Debian/Ubuntu)

```sh
sudo apt update
sudo apt install -y debootstrap qemu-user-static binfmt-support \
                    squashfs-tools xorriso zip git

git clone https://github.com/DaviGayDaSilva/KolinOS
cd KolinOS

sudo bash build.sh
```

Isso gera, em `output/`:

- `kolinos-1.0.0-corvo-arm64.tar.xz` — rootfs
- `kolinos-1.0.0-corvo-arm64.iso` — ISO carrier (não bootável)
- `SHA256SUMS`, `METADATA.txt`

### Opções

| Opção | Efeito |
|---|---|
| `--arch arm64` | alvo (também aceita `amd64`) |
| `--suite trixie` | suíte Debian |
| `--mirror URL` | espelho Debian |
| `--snapshot STAMP` | fixa pacotes no `snapshot.debian.org` (ex.: `20250901T000000Z`) |
| `--reproducible` | atalho: usa a data fixada em `VERSION` como snapshot |
| `--epoch EPOCH` | timestamp Unix fixo p/ todos os artefatos (reprodutível) |
| `--rootfs DIR` | onde construir o rootfs |
| `--output DIR` | onde gravar artefatos |
| `--force` | recria o rootfs do zero |
| `--only 40,50` | roda só os estágios escolhidos |
| `--no-iso` | não gera a ISO |
| `--keep-qemu` | mantém o `qemu-aarch64-static` no rootfs |
| `--no-custom-debs` | não constrói/instala os pacotes KolinOS `.deb` |

## 1b. Pacotes KolinOS (Fase 5)

O estágio `35-packages.sh` empacota `tools/` e `config/branding/` como `.deb`
(`kolinos-base`, `kolinos-tools`, `kolinos-branding`), monta um repositório APT
local e instala via `apt-get`. Para reconstruir só isso:

```sh
sudo bash build.sh --only 35
```

Para gerar e inspecionar os `.deb` sem tocar no rootfs:

```sh
bash scripts/host/build-deb.sh                    # usa a arquitetura de VERSION
KOLIN_DEB_ARCH=arm64 bash scripts/host/build-deb.sh
dpkg-deb -I packages/custom/debs/kolinos-base_1.0.0-1_arm64.deb
dpkg-deb -c packages/custom/debs/kolinos-tools_1.0.0-1_arm64.deb
```

Cada receita vive em `packages/custom/<nome>/` (`debian/control`,
`debian/changelog`, `prebuild.sh`). Detalhes e limitações em `docs/PHASE5.md`.

## 2. Verificar o rootfs

```sh
sudo bash scripts/host/verify-rootfs.sh
```

Checa identidade (`/etc/os-release`), APT/DPKG, usuário padrão, sudo,
ferramentas KolinOS e os pacotes próprios (Fase 5: `dpkg-query`, `dpkg -V`,
`apt-kolinos`, repositório remoto inativo). Sai com código de erro se algo
falhar.

> O verificador precisa saber a arquitetura do alvo quando ela difere de
> `arm64` (ex.: um build de teste amd64):
> `sudo env KOLIN_ARCH=amd64 DEB_ARCH=amd64 bash scripts/host/verify-rootfs.sh`.

## 2b. Verificar que o build é reproduzível

```sh
sudo bash scripts/host/verify-reproducible.sh --snapshot 20250901T000000Z
```

Constrói o rootfs **duas vezes** com o mesmo epoch e compara o SHA-256. Se os
dois arquivos forem idênticos, o build é reprodutível. Veja `docs/PHASE4.md`.

## 3. Entrar no rootfs (host Linux, com root)

```sh
sudo bash scripts/host/enter.sh
```

Dentro do rootfs:

```sh
kolinos-info
cat /etc/os-release
id
apt update
```

## 4. Testar no Termux (Android, sem root)

Transfira `kolinos-1.0.0-corvo-arm64.tar.xz` para o celular (ou baixe de um
release). No Termux:

```sh
pkg update && pkg install -y proot-distro
bash install/kolinos-install.sh /sdcard/Download/kolinos-1.0.0-corvo-arm64.tar.xz
kolinos
```

O instalador unificado detecta o Termux e usa o backend `proot`, que:

1. garante `proot-distro` (e `proot`);
2. localiza o rootfs e confere o SHA-256, se disponível;
3. detecta a versão do proot-distro (v5: arquivo local; v4: plugin);
4. instala o container `kolinos`;
5. cria o atalho `kolinos` em `$PREFIX/bin`;
6. roda o **first boot** (machine-id, resolv.conf, repositório APT);
7. valida executando `cat /etc/os-release` dentro do container.

`scripts/termux/install.sh` continua funcionando: é um shim que encaminha para o
front-end com `--target proot`.

## 4b. Instalar em um host Linux (Fase 6)

```sh
# Verificações do instalador (sem root, sem tocar no sistema):
bash scripts/host/verify-installer.sh --dest /tmp/kolinos-verify

# Implantar o rootfs em um diretório (com root):
sudo KOLIN_ASSUME_YES=1 bash install/kolinos-install.sh --target dir \
     --dest /opt/kolinos output/kolinos-1.0.0-corvo-arm64.tar.xz
sudo chroot /opt/kolinos /bin/bash -l

# Escrever num dispositivo (Fase 10, destrutivo, exige --force):
sudo bash install/kolinos-install.sh --target disk --device /dev/sdX1 \
     --format ext4 --force output/kolinos-1.0.0-corvo-arm64.tar.xz
```

Após `--target dir`, confira o first boot:

```sh
grep -qE '^[0-9a-f]{32}$' /opt/kolinos/etc/machine-id && echo "machine-id OK"
test -f /opt/kolinos/etc/kolinos/firstboot.done && echo "first boot OK"
```

Detalhes e limites por plataforma em [`docs/PHASE6.md`](PHASE6.md).

## 5. Testar a ISO

```sh
# Ver conteúdo sem queimar nada:
xorriso -indev output/kolinos-1.0.0-corvo-arm64.iso -find / -type f

# Montar (requer root):
sudo mkdir -p /mnt/kolinos
sudo mount -o loop,ro output/kolinos-1.0.0-corvo-arm64.iso /mnt/kolinos
ls /mnt/kolinos
sudo umount /mnt/kolinos
```

> A ISO é um **carrier de dados**. Ela não inicializa. Serve para transportar o
> rootfs e o código-fonte.

## 6. Reconstruir só uma parte

```sh
# Só reaplica identidade e usuários:
sudo bash build.sh --only 40,50
# Reempacota:
sudo bash build.sh --only 70,80 --no-iso
```

## 7. Repositório APT próprio (Fase 9, groundwork)

```sh
# Chave de assinatura:
bash repo/scripts/make-gpg-key.sh

# Coloque .deb em packages/custom/debs/ e indexe:
bash repo/scripts/build-repo.sh                 # arquitetura de VERSION
bash repo/scripts/build-repo.sh --arch amd64    # ou escolha a arquitetura

# Sirva localmente:
cd repo/public && python3 -m http.server 8080
```

O repositório é reconstruído do zero a cada execução e só indexa `.deb` da
arquitetura alvo (mais `Architecture: all`). `--unsigned` é para testes locais;
o padrão tenta assinar com a chave criada por `make-gpg-key.sh`.

### Verificar o repositório

```sh
# No host: assinatura, metadados, apt-get update e download de cada pacote.
bash scripts/host/verify-repo.sh

# Dentro do rootfs arm64: apt resolve e baixa um pacote KolinOS de verdade.
# Precisa de root (usa chroot e bind mounts) e de qemu-user-static.
sudo bash scripts/host/qemu-apt-test.sh
```

Os dois scripts falham com mensagem explícita quando algo está errado. O
segundo precisa de `qemu-user-static` no host; ele instala
`tools/host/qemu-method-wrapper.c` (compilado nativo) sobre os helpers que o
APT executa, porque o chroot não executa binários arm64. O desempacotamento via
`dpkg` não completa aí — o qemu-user não emula `execve` de binários do guest —,
o que o script reporta como limitação do ambiente. Para desempacotar de fato,
use `proot` (Termux) ou `binfmt_misc` (com root); veja `docs/LIMITATIONS.md`.
