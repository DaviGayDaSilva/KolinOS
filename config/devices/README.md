# Perfis de dispositivo (FASE 10)

Um perfil descreve **como um alvo inicializa** e **quais artefatos ele precisa**.
O build não adivinha: sem `--device <perfil>` nada específico de hardware é
gerado, e o resultado é o das fases 1–9 (rootfs + imagem UEFI genérica).

Um perfil é um arquivo `.conf` em shell, carregado com `source`. Só variáveis e
comentários — nenhum comando é executado ao carregar.

## Campos

| campo | significado |
|---|---|
| `KOLIN_DEVICE_ID` | identificador (= nome do arquivo, sem `.conf`) |
| `KOLIN_DEVICE_LABEL` | nome legível |
| `KOLIN_DEVICE_KIND` | `uefi` \| `sbc` \| `android` |
| `KOLIN_DEVICE_BOOTLOADER` | firmware que carrega o kernel |
| `KOLIN_DEVICE_KERNEL` | pacote Debian do kernel (`""` = o da imagem) |
| `KOLIN_DEVICE_KERNEL_FLAVOR` | sufixo do `vmlinuz-*` em `/boot` (`""` = o mais recente) |
| `KOLIN_DEVICE_DTB_DIR` | diretório de device trees no rootfs (`""` = não há) |
| `KOLIN_DEVICE_DTB` | lista de `.dtb` a copiar (só SBC; `""` = nenhum) |
| `KOLIN_DEVICE_CMDLINE` | kernel command line (`@KOLIN_ROOT_UUID@` é substituído) |
| `KOLIN_DEVICE_INITRD_MODULES` | módulos injetados no initramfs |
| `KOLIN_DEVICE_EXTRA_PKGS` | pacotes extras além dos da imagem |
| `KOLIN_DEVICE_BOOTIMG` | `1` = gerar `boot.img` Android (só `kind=android`) |
| `KOLIN_DEVICE_NOTES` | ressalva exibida antes de gravar |

## Perfis disponíveis

| perfil | kind | inicializa? | onde |
|---|---|---|---|
| `generic-uefi` | uefi | sim | QEMU `virt`, VMs ARM64, placas com UEFI arm64 |
| `rpi4` | sbc | sim¹ | Raspberry Pi 4/400 (UEFI em firmware ou U-Boot) |
| `android-generic` | android | não² | celular Android com bootloader desbloqueado |

¹ O RPi não tem UEFI de fábrica. O perfil assume firmware UEFI instalado
(típico em Pi 4 com `rpi-eeprom` atualizado e uma ESP) ou U-Boot encadeado.
² O `boot.img` gerado é um **artefato real e verificável**, mas quase nunca
inicializa: o kernel Debian genérico não traz os drivers (GPU, modem, Wi-Fi,
touch) nem a device tree do aparelho. Ver `docs/PHASE10.md`.

## Viabilidade na máquina atual

```sh
bash config/devices/report.sh            # todos os perfis
bash config/devices/report.sh android-generic
```

O relatório diz o que dá para construir **aqui** e o que exige outra máquina —
por exemplo, quase todo passo de Android exige `root` de verdade, porque o
`boot.img` precisa de `mknod` e o build do initramfs escreve em `/dev`.
