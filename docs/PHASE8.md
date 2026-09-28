# FASE 8 — Imagens distribuíveis

**Objetivo:** transformar o rootfs personalizado em artefatos que alguém possa
baixar, gravar e inicializar — não só extrair num `chroot`.

Até a FASE 7 o projeto produzia um `tar.xz` do rootfs e um ISO que era apenas um
**carrier** (um CD de dados com o tar dentro). Nada disso inicializa. Esta fase
adiciona uma imagem de disco **realmente inicializável** e verifica o boot de
verdade, dentro de uma VM.

---

## O que foi produzido

| Artefato | Inicializável? | Para que serve |
|---|---|---|
| `kolinos-<ver>-<cod>-<arch>.tar.xz` | não | rootfs para `proot-distro` (Termux), chroot, `dir`/`systemd-nspawn` |
| `kolinos-<ver>-<cod>-<arch>.img` | **sim (UEFI)** | disco GPT: ESP FAT32 (GRUB + kernel + initrd) + root ext4 |
| `kolinos-<ver>-<cod>-<arch>.img.xz` | **sim (UEFI)** | o mesmo, comprimido, para gravar com `dd`/`xz -d` |
| `kolinos-<ver>-<cod>-<arch>.iso` | não | carrier de dados: rootfs + código-fonte + instalador |

A distinção importa: o `.tar.xz` continua sendo o artefato principal para
**celular/Termux**, e o `.img` é o artefato para **VM, placa ARM64 e UEFI**.

---

## O que "inicializável" significa aqui, e o que não significa

O `.img` inicializa em **UEFI**: firmware → `BOOTAA64.EFI` (GRUB) → kernel →
initramfs → systemd. Isso cobre QEMU `virt`, VMs ARM64, placas que expõem UEFI
(alguns SBCs, máquinas virtuais de nuvem) e PCs ARM64.

**Não** é uma imagem de celular. Um telefone Android não inicializa por UEFI: ele
precisa de um bootloader próprio (ABL/LK), de uma partição `boot` com kernel
assinado pelo fabricante e de uma **device tree** específica do aparelho. Nada
disso é genérico, e gravar um `.img` genérico no armazenamento de um celular não
o torna inicializável. Isso é FASE 10, e depende de desbloqueio de bootloader e
de kernel próprio. Ver `docs/LIMITATIONS.md`.

---

## Como o estágio 85 monta a imagem

`build/stages/85-image.sh` roda **sem `loop device`**, porque contêineres quase
sempre não têm `/dev/loop*` nem `CAP_MKNOD`. Em vez de montar partições, ele
manipula o arquivo de imagem diretamente:

| Etapa | Ferramenta | Por que não precisa de loop |
|---|---|---|
| tabela GPT | `parted` | opera no arquivo, não em dispositivo |
| partição root ext4 | `mke2fs -E offset=… -d <rootfs>` | copia a árvore para dentro do fs durante a criação |
| ESP FAT32 | `mformat`/`mmd`/`mcopy` | mtools aceita `imagem@@offset` |
| UUIDs | `dumpe2fs`, `blkid` | leitura direta |
| bootloader EFI | `grub-mkstandalone` **dentro do rootfs** | o host x86 não tem os módulos `arm64-efi` |

Detalhe importante: o `grub-mkstandalone` roda **dentro do rootfs arm64** (via
`kolin_run`, isto é, qemu-user), porque os módulos `arm64-efi` vivem lá. O
`objcopy` do host x86 não reconhece ELF aarch64 — testado e confirmado.

### Por que o tamanho é calculado

A partição root é dimensionada a partir do uso real (`du`) mais 15%, e o ext4 é
criado sem journal (`^has_journal`) porque uma imagem somente-leitura não se
beneficia dele. A ESP tem 128 MiB fixos (kernel ~36 MiB + initrd ~34 MiB +
GRUB + fundo do menu).

---

## Fstab: o rootfs não pode carregar o fstab da imagem

O fstab distribuído no rootfs é **vazio de propósito** — em proot e em chroot ele
nem é consultado. A imagem precisa de entradas reais, senão o sistema não
encontra seu próprio root. O estágio escreve o fstab com o UUID real, monta a
imagem e **restaura o fstab vazio** no fim, para que um `tar`/ISO posterior não
herde entradas que só fazem sentido na imagem.

---

## Menu de boot com identidade

`config/boot/grub.cfg.in` é renderizado com o UUID real do root (nunca nomes de
dispositivo, que mudam de máquina para máquina) e traz três entradas:

1. **KolinOS 1.0.0 (Corvo)** — boot normal, `quiet`.
2. **KolinOS (modo verboso, diagnóstico)** — `loglevel=7`.
3. **KolinOS (single user / recuperação)** — `init=/bin/bash`.

O fundo é o wallpaper Corvo Glass convertido de SVG para PNG com
`rsvg-convert`, porque o GRUB lê PNG e não SVG. O menu referencia apenas os
terminais `gfxterm` e `console`: ambos sempre existem. Citar o terminal `serial`
falha com `terminal 'serial' isn't found` nesta build do GRUB (o módulo não fica
registrado) e imprime ruído a cada boot. Em máquina headless o console do
firmware **é** a porta serial, então o menu continua visível de qualquer forma.

### Armadilha de ordem: o fstab tem que ser escrito antes do `mke2fs`

`mke2fs -d` fotografa a árvore no instante em que roda. Escrever o fstab da
imagem **depois** produz um disco cujo `/etc/fstab` está vazio — o sistema
inicializa pelo `root=` do kernel e ignora o arquivo, então o defeito só
aparece quando algo depende do fstab. O estágio escreve o fstab primeiro,
formata depois.

---

## Como testar o boot

`scripts/host/qemu-boot.sh` inicializa o artefato sob QEMU aarch64 + EDK2/AAVMF
e espera um marcador no console serial, em vez de dormir um tempo fixo:

```bash
# rootfs direto, via virtio-9p (sem imagem, sem loop device)
sudo bash scripts/host/qemu-boot.sh --rootfs ./rootfs

# a imagem de disco, exercitando firmware → GRUB → kernel
sudo bash scripts/host/qemu-boot.sh --image output/kolinos-1.0.0-corvo-arm64.img
```

O modo `--rootfs` é útil durante o desenvolvimento: não exige montar nada, então
funciona no mesmo contêiner onde o build roda. O modo `--image` é o teste que
importa para esta fase, porque só ele exercita o caminho de boot completo.

O script boota uma **cópia** da imagem: o systemd escreve no journal já no
primeiro boot, então inicializar o arquivo em `output/` no lugar o alteraria e
invalidaria o checksum publicado. Ele também remove o diretório temporário ao
sair (sem isso, cada boot vaza uma cópia de 1,4 GiB em `/tmp`).

Boot verificado (TCG, sem KVM, portanto lento — alguns minutos):

```
UEFI firmware (version 2025.02-8+deb13u1)
BdsDxe: starting Boot0001 "UEFI Misc Device"
                        GNU GRUB  version 2.12-9+deb13u2
 |*KolinOS 1.0.0 (Corvo)
  Booting `KolinOS 1.0.0 (Corvo)'
KolinOS 1.0.0 (Corvo) kolinos ttyAMA0
kolinos login:
```

---

## Defeitos encontrados e corrigidos nesta fase

Ao inspecionar os artefatos já existentes, antes de gerar a imagem, apareceram
dois bugs de empacotamento que afetavam **todo** rootfs distribuído:

### 1. `/dev/null` era um arquivo comum

O tar continha `./dev/null` como arquivo regular de 0 bytes (e, no rootfs de
trabalho, de 793 bytes com saída de `apt` dentro). Causa: quando o `chroot` não
recebe `/dev` montado, `>/dev/null` cria um arquivo comum e engole a saída
silenciosamente — que depois ia para o arquivo distribuído.

Correção: `kolin_fix_dev()` remove qualquer arquivo comum onde deveria haver
device node e recria os nós quando o kernel permite `mknod`. Em contêiner sem
`CAP_MKNOD`, os nós vêm de devtmpfs no boot (o kernel Debian tem
`CONFIG_DEVTMPFS=y`) ou do proot. O tar nunca mais carrega um `/dev/null` falso.

### 2. Donos errados — nos dois sentidos

- `tar --owner=0 --group=0` **apagava** ids legítimos: `/home/kolin` saía como
  `0/0` com modo `0700`, ou seja, o usuário não conseguia ler o próprio home.
- Arquivos criados por redirecionamento (`cat >`, `install -d`) herdavam o uid do
  **host** (10001), que não existe no rootfs, e apareciam assim no archive.

Correção: `kolin_normalize_owners()` mapeia para `root:root` apenas os ids **sem
conta correspondente** em `/etc/passwd`/`/etc/group` do rootfs, e preserva o
resto; o tar usa `--numeric-owner` sem `--owner=0`. O estágio 50 também passa a
`chown` explícito do home com os ids numéricos do alvo, porque `useradd` roda sob
qemu-user e o host vê outro uid.

Ambos foram confirmados no tar distribuído (`tar -tvf`) antes e depois da
correção.

---

## Reprodutibilidade

UUIDs de partição são derivados de `sha256` do nome (não aleatórios), o serial do
FAT é derivado do nome da imagem, e o `mtime` de tudo é fixado no
`KOLIN_BUILD_EPOCH`. Dois builds do mesmo commit produzem os mesmos
identificadores.

O kernel e o initramfs, porém, **não** são byte-reprodutíveis: o Debian gera o
initramfs com conteúdo dependente do host de build. Os UUIDs e a estrutura
continuam estáveis.

---

## Limitações desta fase

- **Sem KVM**: o boot de teste roda em emulação TCG. É lento (minutos) e serve
  para provar que o sistema chega ao userspace, não para medir desempenho.
- **Só UEFI**: sem GRUB BIOS (`i386-pc`), porque o alvo é ARM64. Um PC x86 não
  inicializa este `.img`.
- **Sem instalador gráfico**: o ISO continua sendo carrier de dados. Um instalador
  Calamares-like é FASE 6/9.
- **`mke2fs -d`** copia a árvore, mas não preserva `xattrs` de forma completa;
  capacidades de arquivo (`security.capability`) podem se perder na imagem. O
  `tar.xz` preserva (usa `--xattrs`).

---

## Verificação desta fase

```bash
# estrutura da imagem
parted -s output/kolinos-*.img unit MiB print
mdir -i output/kolinos-*.img@@1M -/ ::        # conteúdo da ESP
dumpe2fs -h output/kolinos-*.img             # só se extrair a partição 2

# boot real
sudo bash scripts/host/qemu-boot.sh --image output/kolinos-*.img

# integridade
sha256sum -c output/SHA256SUMS
```

Resultado esperado: menu GRUB com a marca, kernel carregando, e o prompt
`kolinos login:` no console.
