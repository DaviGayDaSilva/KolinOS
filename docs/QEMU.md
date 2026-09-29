# Emular o KolinOS no QEMU

**Objetivo:** rodar o KolinOS dentro do QEMU no seu computador — o mesmo QEMU
que o Limbo usa no Android (ver [`LIMBO.md`](LIMBO.md)) — para testar boot,
login e o sistema sem depender de hardware real.

Como o KolinOS é `arm64` e o host quase sempre é `x86_64`, a emulação é por
software (TCG), sem KVM. **O boot leva alguns minutos.** Isso é esperado; não é
travamento.

---

## 1. Dependências

No host (Debian/Ubuntu):

```sh
sudo apt install -y qemu-system-arm qemu-efi-aarch64 ipxe-qemu
```

| Pacote | Fornece |
|---|---|
| `qemu-system-arm` | `qemu-system-aarch64` |
| `qemu-efi-aarch64` | firmware UEFI AAVMF (`/usr/share/AAVMF/AAVMF_CODE.fd`) |
| `ipxe-qemu` | `efi-virtio.rom` — **obrigatório** para `virtio-net-pci` |

O firmware é obrigatório no modo `--image`: a imagem do KolinOS contém um ESP
com GRUB EFI, e **não** um bootloader de BIOS. Sem AAVMF, o QEMU não tem código
de firmware para inicializar.

`ipxe-qemu` é fácil de esquecer: sem ele, o QEMU falha logo na inicialização com

```
-device virtio-net-pci,netdev=n0: failed to find romfile "efi-virtio.rom"
```

O dispositivo de rede pede um ROM de boot (PXE) para a placa virtio. Se você não
precisa de rede, remova o par `virtio-net-pci`/`netdev` em vez de instalar o
pacote — mas o script inclui rede por padrão, então na prática instale o pacote.

Confira:

```sh
command -v qemu-system-aarch64
ls /usr/share/AAVMF/AAVMF_CODE.fd
ls /usr/share/qemu/efi-virtio.rom
```

> Se o caminho do firmware for outro, veja §6 (o script procura em três locais).

---

## 2. Modo mais rápido: já tem uma imagem?

O projeto já produz `output/kolinos-1.0.0-corvo-arm64.img` (ver
[`PHASE8.md`](PHASE8.md)). Para inicializá-la:

```sh
bash scripts/host/qemu-boot.sh --image output/kolinos-1.0.0-corvo-arm64.img
```

O script:

1. copia a imagem para um diretório temporário antes de inicializar;
2. inicializa com AAVMF + a imagem;
3. espera um marcador no console serial (padrão: `login:|Reached target`);
4. sai com **0** se alcançou o usuário, **1** se estourou o tempo.

**Por que a cópia?** O systemd escreve no journal já no primeiro boot. Iniciar a
imagem distribuída no lugar a modificaria — e o SHA-256 publicado deixaria de
valer. A cópia descartável mantém `output/` intacto.

Se tudo der certo, o fim da saída é:

```
KolinOS 1.0.0 (Corvo) kolinos ttyAMA0

KolinOS é baseado em Debian. Documentação: https://github.com/DaviGayDaSilva/KolinOS
kolinos login:
```

### Opções úteis

| Opção | Para quê |
|---|---|
| `--ram 4096` | mais memória (padrão: 2048 MiB; mínimo prático ~512) |
| `--cpus 4` | mais núcleos (padrão: 2) — ajuda pouco sem KVM |
| `--timeout 900` | máquina lenta ou primeira inicialização longa (padrão: 420s) |
| `--expect 'login:'` | marcador mais estrito |
| `--log meu.log` | grava o console serial em outro arquivo |
| `--extra '-vnc :1'` | argumentos crus repassados ao QEMU (ex.: VNC) |

O console serial é gravado em `output/qemu-boot.log`, com o log do script ao
lado. Em outra aba:

```sh
tail -f output/qemu-boot.log
```

---

## 3. Modo sem imagem: inicializar o `rootfs/` direto

Durante o desenvolvimento você não quer regerar 1.4 GiB de imagem a cada
mudança. O QEMU compartilha o diretório `rootfs/` do host com o guest via
**virtio-9p**, sem criar disco:

```sh
sudo bash scripts/host/qemu-boot.sh --rootfs ./rootfs
```

O kernel e o initrd saem de `rootfs/boot/` — por isso o rootfs precisa de
`linux-image-arm64` e `initramfs-tools` (o estágio 85 exige que existam).

| | `--rootfs` | `--image` |
|---|---|---|
| Precisa de imagem | não | sim |
| Exercita o GRUB/UEFI | não | **sim** |
| Ciclo de teste | segundos | minutos |
| Serve para | editar o rootfs e re-testar | validar o artefato distribuído |

Use `--rootfs` enquanto mexe no sistema. Rode `--image` **antes de publicar**:
só ele prova que a cadeia firmware → GRUB → kernel → systemd funciona de ponta a
ponta.

---

## 4. Boot manual (sem o script)

Para entender o que o script faz, ou para depurar, o comando por baixo é:

```sh
# copie o firmware variável: o CODE é somente leitura, o VARS precisa ser gravável
cp /usr/share/AAVMF/AAVMF_VARS.fd /tmp/vars.fd

qemu-system-aarch64 \
    -machine virt -cpu cortex-a72 -smp 2 -m 2048 \
    -nographic -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/tmp/vars.fd \
    -drive if=none,format=raw,file=output/kolinos-1.0.0-corvo-arm64.img,id=hd0 \
    -device virtio-blk-pci,drive=hd0,bootindex=0 \
    -device virtio-net-pci,netdev=n0 \
    -netdev user,id=n0
```

Pontos que costumam causar erro:

- **dois** arquivos de firmware. O `CODE` entra com `readonly=on`; o `VARS` é a
  cópia gravável onde a UEFI guarda as variáveis de boot. Apontar `-bios` para um
  único arquivo também funciona, mas as entradas de boot não persistem.
- `bootindex=0` no disco: sem isso a UEFI pode tentar a rede primeiro.
- `-no-reboot`: se o kernel entrar em pânico, o QEMU para em vez de reiniciar em
  laço e poluir o log.
- `-nographic`: redireciona o console serial para o terminal. A placa `virt` usa
  `ttyAMA0`, e o KolinOS já configura o console nele.

Para sair do `-nographic`, use `Ctrl-a x`.

---

## 5. Login e uso

Usuário `kolin`, senha `kolinos` (pública e documentada — **troque no primeiro
login** com `passwd`). Hostname padrão: `kolinos`.

Dentro do guest:

```sh
cat /etc/os-release     # confirma a identidade KolinOS
cat /etc/motd           # motd próprio
uname -m                # aarch64
```

Se você só quer conferir o sistema sem uma sessão completa, o marcador padrão do
script já é prova suficiente: ele só aparece quando o `getty` já está rodando.

---

## 6. Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| Para em `UEFI Interactive Shell` | firmware não achou o ESP/GRUB, ou `bootindex` ausente | confirme o ESP na imagem; use o script, que já passa `bootindex=0` |
| "sem firmware UEFI aarch64" | `qemu-efi-aarch64` não instalado | `sudo apt install qemu-efi-aarch64` |
| Nada na tela, sem erro | console não está no serial | `-append` deve ter `console=ttyAMA0`; no modo `--image` isso já está no GRUB |
| Kernel panic: não achou a raiz | UUID do fstab ≠ UUID real da partição | regenere a imagem (o estágio 85 escreve o fstab com o UUID determinístico) |
| Boot lento demais | TCG sem KVM | normal; aumente `--timeout`; ver §7 |
| `--rootfs` não monta a raiz | `9p` não habilitado no kernel | `CONFIG_NET_9P_VIRTIO`; o kernel Debian já traz |
| `failed to find romfile "efi-virtio.rom"` | falta `ipxe-qemu` | `sudo apt install ipxe-qemu` (ver §1) |
| Processo continua após fechar | QEMU órfão | `pkill -f 'qemu-system-aarch64.*kolinos'` |

---

## 7. Por que é lento (e o que dá para acelerar)

O host é `x86_64` e o guest é `aarch64`: cada instrução ARM é traduzida em
software (TCG). **Não há KVM para instruções cruzadas** — KVM só acelera quando
host e guest são a mesma arquitetura.

Opções:

- **`-smp` maior** ajuda pouco: o TCG tem um único tradutor por vCPU, e o ganho
  real exige MTTCG, que na `virt` já vem ligado.
- **Máquina com host `arm64`** (Apple Silicon, servidor ARM, Raspberry Pi): aqui
  o QEMU pode usar `-accel kvm` e o boot cai de minutos para segundos. É a única
  aceleração real. Verifique com `ls /dev/kvm`.
- **Reduza o guest**: RAM menor e um perfil enxuto (`--slim`) inicializam mais
  rápido que o perfil com desktop.

Não tente `-accel kvm` num host `x86_64`: o QEMU recusa (`invalid accelerator`).

---

## 8. Onde o QEMU se encaixa no projeto

| Ferramenta | O que valida |
|---|---|
| `scripts/host/verify-rootfs.sh` | identidade, usuário, APT/DPKG — **sem inicializar** |
| `scripts/host/qemu-boot.sh --rootfs` | que o rootfs chega ao login (9p) |
| `scripts/host/qemu-boot.sh --image` | que o **artefato distribuído** inicializa (UEFI + GRUB) |
| `scripts/host/verify-repo.sh` | que o repositório APT publicado é verificável |
| Limbo no Android | o mesmo guest num emulador de celular (ver `LIMBO.md`) |

Este guia cobre o QEMU no desktop. O documento do Limbo cobre o Android, onde as
limitações são outras (sem KVM, tela via VNC, máquina `virt` virtio-only).

---

## 9. Não confunda: a ISO não inicializa

`output/kolinos-1.0.0-corvo-arm64.iso` é um **carrier de dados** (rootfs +
código-fonte + instalador), gerado com `xorriso -as mkisofs` **sem** El Torito.
Confira você mesmo:

```sh
xorriso -indev output/kolinos-1.0.0-corvo-arm64.iso -report_el_torito plain
```

Não há seção de boot El Torito — ou seja, essa ISO **não** inicializa no QEMU
nem em PC nenhum. Para inicializar o KolinOS, use o `.img` (§2) ou o `--rootfs`
(§3). Tratar a ISO como CD de boot é a confusão mais comum.
