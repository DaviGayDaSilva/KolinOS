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
| `--rootfs DIR` | onde construir o rootfs |
| `--output DIR` | onde gravar artefatos |
| `--force` | recria o rootfs do zero |
| `--only 40,50` | roda só os estágios escolhidos |
| `--no-iso` | não gera a ISO |
| `--keep-qemu` | mantém o `qemu-aarch64-static` no rootfs |

## 2. Verificar o rootfs

```sh
sudo bash scripts/host/verify-rootfs.sh
```

Checa identidade (`/etc/os-release`), APT/DPKG, usuário padrão, sudo,
ferramentas KolinOS. Sai com código de erro se algo falhar.

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
bash scripts/termux/install.sh /sdcard/Download/kolinos-1.0.0-corvo-arm64.tar.xz
kolinos
```

O instalador:

1. garante `proot-distro` (e `proot`);
2. localiza/baixa o rootfs;
3. confere o SHA-256, se disponível;
4. detecta a versão do proot-distro (v5: arquivo local; v4: plugin);
5. instala o container `kolinos`;
6. cria o atalho `kolinos` em `$PREFIX/bin`;
7. valida executando `cat /etc/os-release` dentro do container.

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
bash repo/scripts/build-repo.sh

# Sirva localmente:
cd repo/public && python3 -m http.server 8080
```
