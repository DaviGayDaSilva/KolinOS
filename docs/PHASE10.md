# FASE 10 — Suporte a hardware real

**Objetivo:** levar o KolinOS de "roda em proot/chroot/QEMU" para "inicializa em
um dispositivo", produzindo artefatos por dispositivo e dizendo com clareza o que
depende de hardware e de decisões que não cabem num contêiner.

Esta é a fase em que a maior parte do trabalho **não** é escrever shell: é
reconhecer o que não pode ser feito aqui e documentar o caminho.

---

## O que a fase acrescenta

| Peça | Arquivo | Função |
|---|---|---|
| Perfis de dispositivo | `config/devices/*.conf` | descrevem um alvo: bootloader, device trees, cmdline |
| Estágio de dispositivo | `build/stages/90-device.sh` | gera o artefato do alvo (dtbs na ESP, `boot.img`) |
| Compressão final | `build/stages/95-compress.sh` | comprime a imagem **uma vez**, após o estágio 90 |
| Relatório de host | `config/devices/report.sh` | diz o que este host consegue e não consegue fazer |
| Ferramenta nativa | `src/kolinos-bootimg/` | lê e valida um `boot.img` Android (header v0/v1/v2) |
| Menu com DTB | `config/boot/grub-dtb.cfg.in` | entrada GRUB que carrega uma device tree |

Uso:

```
sudo bash build.sh --list-devices
sudo bash build.sh --device rpi4 --with-image
sudo bash build.sh --device android-generic
```

`--device` implica `--with-image` para perfis `uefi` e `sbc` (eles *são* a
imagem); perfis `android` geram um `boot.img` e não precisam de imagem de disco.

---

## Por que a compressão virou um estágio separado

A FASE 8 comprimia a imagem ao final do estágio 85. Na FASE 10 o estágio 90
**modifica** essa mesma imagem (acrescenta as device trees do board à ESP). Se a
compressão continuasse no 85, o `.img.xz` sairia de um `.img` que já não existe
— um checksum válido descrevendo bytes diferentes. Comprimir no fim, uma única
vez, resolve as duas coisas: o artefato casa com a imagem e um build de 1,4 GiB
não paga dois passes de `xz`. O estágio 95 também pula a compressão quando o
`.xz` já é mais novo que o `.img`, para que rodar `--only 95` de novo seja barato.

---

## Perfis

| Perfil | kind | O que produz |
|---|---|---|
| `generic-uefi` | uefi | a imagem UEFI da FASE 8, com notas de build |
| `rpi4` | sbc | a imagem UEFI + device trees `bcm2711` na ESP + menu com `devicetree` |
| `android-generic` | android | um `boot.img` (header v2) validado por `kolinos-bootimg` |

Um perfil é shell lido em subshell, nunca no shell do build — um perfil não deve
poder alterar o estado do build por estar sendo lido. As chaves são
`KOLIN_DEVICE_*`:

```sh
KOLIN_DEVICE_ID="rpi4"
KOLIN_DEVICE_KIND="sbc"              # uefi | sbc | android
KOLIN_DEVICE_BOOTLOADER="..."        # texto, para o relatório
KOLIN_DEVICE_DTB_DIR="broadcom"      # subdiretório de /usr/lib/linux-image-*/
KOLIN_DEVICE_DTB="bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb"
KOLIN_DEVICE_CMDLINE="root=UUID=@KOLIN_ROOT_UUID@ ro quiet ..."
```

`KOLIN_DEVICE_EXTRA_PKGS` instala pacotes **no alvo**. Ferramenta de build (como
`mkbootimg`) nunca entra aí: ela roda no host e não existe no rootfs arm64.

---

## O que cada alvo exige de verdade

### Raspberry Pi 4 (`rpi4`)

Um Pi não tem UEFI de fábrica. O firmware VideoCore lê `config.txt`/`cmdline.txt`
de uma FAT e procura um kernel — mas o kernel "natural" ali é o do
`raspberrypi/firmware`, não o Debian. O perfil assume o outro caminho:

```
firmware -> EEPROM com UEFI (rpi-eeprom-update) -> GRUB -> kernel Debian
```

Exige, portanto:

- **EEPROM atualizado** para o bootloader UEFI, ou U-Boot encadeado.
- Gravar a imagem no cartão/USB: `dd if=kolinos-…-rpi4.img of=/dev/sdX bs=4M`.
- A device tree certa para o modelo (Pi 4B vs 400) — o menu traz uma entrada por
  arquivo copiado; o padrão é o primeiro em ordem alfabética.

O que o estágio **faz** aqui: copia as dtbs do kernel Debian para a ESP,
**valida cada uma com `dtc`** (um arquivo com o nome certo mas conteúdo errado
passaria por um `cp`), e escreve um `grub-dtb.cfg` com o UUID real da raiz.
O que ele **não** faz e não pode fazer: atualizar EEPROM, nem gravar o cartão.

### Android genérico (`android-generic`)

Um telefone não inicializa por UEFI. Ele tem bootloader próprio (ABL/LK), uma
partição `boot` com um `boot.img` no formato AOSP e um kernel do fabricante.

```
fastboot flash boot kolinos-…-android-generic-boot.img
```

Exige: **bootloader desbloqueado** e o aparelho por USB.
O `boot.img` gerado aqui tem header v2, kernel e initrd do Debian, e uma DTB.

Sejamos diretos: **ele quase certamente não inicializa.** O kernel Debian
genérico não tem os drivers do SoC (display, armazenamento, PMIC) nem a DTB do
aparelho. Isso não é um defeito do artefato — um `boot.img` válido e bem formado
é a *base*; um kernel que inicializa um telefone específico é um trabalho de
port, kernel próprio e provavelmente `mkbootimg` com os offsets daquele modelo.
O perfil existe para provar o formato, não para prometer boot.

O estágio resolve isso com honestidade: gera a DTB do perfil se houver, senão
uma DTB mínima válida (o header v2 **exige** uma dtb não vazia), avisa que ela é
placeholder, e valida o resultado com `kolinos-bootimg` — um parser independente,
feito aqui — antes de qualquer `fastboot`.

### UEFI genérico (`generic-uefi`)

Nada além da imagem da FASE 8. Serve para QEMU `virt`, VMs ARM64 e placas que já
expõem UEFI. O artefato é o mesmo; o perfil só o rotula e emite as notas.

---

## A ferramenta nativa `kolinos-bootimg`

`src/kolinos-bootimg/kolinos-bootimg.c` lê o header empacotado do AOSP
(`ANDROID!`) nas versões 0, 1 e 2: kernel, ramdisk, dtb, tags, página, cmdline e
`id`. Comandos:

```
kolinos-bootimg info  <boot.img>     # imprime cabeçalho, layout e verificações
kolinos-bootimg verify <boot.img>    # sai 0 se íntegro, 1 se não
```

Ela recusa o que não é um `boot.img`, um arquivo truncado, uma página que não é
potência de dois, e um header v3 (formato diferente, ainda não suportado). O
teste positivo/negativo está em `make test`.

Por que ter a ferramenta própria: `mkbootimg` **gera** a imagem; ela **lê** e
confere. Um erro de layout produz um arquivo que o `mkbootimg` aceita e o
`fastboot` recusa. Validar com um parser independente pega isso no build.

---

## O relatório de host

```
bash config/devices/report.sh rpi4
```

Responde, para o host atual: há `dtc`, `mcopy`, `mkbootimg`, `fastboot`? Há USB
e root? Chega a um dispositivo? É o que separa "o build passou" de "o
dispositivo vai inicializar" — e mostra, sem rodeios, o que este contêiner não
tem.

---

## Testar o que dá para testar

| Teste | Onde | Comando |
|---|---|---|
| Sintaxe dos estágios | host | `bash -n build/stages/90-device.sh` |
| Ferramentas de host | host | `bash config/devices/report.sh rpi4` |
| Ferramenta nativa | host | `make test` |
| Build do artefato | host (root) | `sudo bash build.sh --device rpi4 --with-image` |
| Conteúdo da ESP | host | extrair 128 MiB do offset 1 MiB e `mdir -i` |
| Device trees | host | `dtc -I dtb -O dts <arquivo> -o /dev/null` |
| `boot.img` | host | `kolinos-bootimg verify <arquivo>` |
| Boot UEFI | QEMU | `sudo bash scripts/host/qemu-boot.sh --image <img>` |
| Boot do Pi | **hardware** | gravar e ligar |
| Boot do celular | **hardware + kernel próprio** | `fastboot flash boot` |

O boot do Pi e do celular **não** é testável aqui, e não é uma lacuna de
processo: exige o dispositivo. O que a fase garante é que o artefato que chega
ao dispositivo está bem formado e foi validado.

---

## Limites que a fase respeita

- **Sem root no host**, não há `mke2fs -d` nem `parted` na imagem; o estágio 85
  já assume um build com root e o diz.
- **Sem dispositivos de loop**, a ESP é editada por `mtools` (dentro do arquivo)
  e o ext4 é escrito direto (`mke2fs -d`, `-E offset=`). Por isso o estágio 90
  consegue acrescentar dtbs a uma imagem existente sem montar nada.
- **Sem `binfmt_misc`/`proot`**, o build não roda o rootfs arm64 num host x86_64.
  Ver `docs/LIMITATIONS.md`; num Termux o caminho é `proot-distro`.
- A ESP tem um teto: as dtbs e o `grub-dtb.cfg` cabem nos 128 MiB, e o estágio
  falha de forma visível (`mcopy` recusa) se um perfil futuro estourar isso.
