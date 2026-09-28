# KolinOS no Limbo PC Emulator — requisitos

**Objetivo:** documentar o que é preciso para rodar o KolinOS dentro do
[Limbo PC Emulator](https://github.com/limboemu/limbo) (QEMU para Android),
separando requisito de **host**, de **guest**, de **firmware** e de **build** —
sem apresentar como pronto o que não existe.

Os fatos abaixo foram conferidos no código-fonte do Limbo
(`limbo-android-lib`, `limbo-android-arm`), porque a documentação do projeto é
contraditória (ver §1).

---

## 1. O que o Limbo emula (e a confusão da documentação)

O enum de arquiteturas do Limbo é explícito:

```java
public enum Arch { x86, x86_64, arm, arm64, ppc, ppc64, sparc, sparc64 }
```

e a biblioteca carregada segue a arquitetura do guest:

| `Arch` | Biblioteca QEMU |
|---|---|
| `x86` / `x86_64` | `libqemu-system-i386.so` / `libqemu-system-x86_64.so` |
| `arm` / **`arm64`** | `libqemu-system-arm.so` / **`libqemu-system-aarch64.so`** |
| `ppc` / `ppc64` | `libqemu-system-ppc.so` / `libqemu-system-ppc64.so` |
| `sparc` / `sparc64` | `libqemu-system-sparc.so` / … |

Ou seja: **o Limbo tem guest ARM64.** O app ARM inclusive se declara assim:

```java
// limbo-android-arm/.../arm/LimboEmuActivity.java
LimboApplication.arch = Config.Arch.arm64;
```

A confusão vem de que as listas de CPU mostradas em wikis antigas
(`arm926`, `arm946`, `arm1026`) são todas **ARMv5/V7 de 32 bits**, e o modelo de
máquina padrão do app ARM é:

```java
arch = "ARM";  machineType = "versatilepb";  cpu = "Default";
```

`versatilepb` é uma placa **ARM 32-bit**. Um kernel aarch64 não inicializa nela.

> **Conclusão prática:** o KolinOS `arm64` **pode** rodar no Limbo, mas não do
> jeito que o app vem configurado. É preciso (a) forçar uma máquina aarch64
> (`-M virt`) e (b) forçar uma CPU de 64 bits (`-cpu cortex-a53`/`max`). Nenhum
> dos dois é o padrão.

Isso muda o plano em relação ao caminho "compilar o KolinOS para x86": a rota
arm64 reaproveita o rootfs, o kernel e o initrd que **já existem** na FASE 8.
Esta é a rota principal do documento. A rota x86 fica na §7.

---

## 2. Requisitos do host (Android + Limbo)

### 2.1 Dispositivo

| Item | Requisito | Observação |
|---|---|---|
| Android | 5.0+ | exigência do Limbo 6.0.0 |
| ABI | `arm64-v8a` | só host 64-bit habilita MTTCG (o app checa `isHost64Bit()`) |
| CPU | 4 núcleos+ | emulação TCG por software; MTTCG tem ganho real no arm64 |
| RAM | 4 GB+ no aparelho | guest usa 1 GiB; o Android precisa do resto |
| Armazenamento | 4 GB+ livres | disco do guest + estado/snapshots |

### 2.2 Aplicativo

- Limbo 6.0.0, QEMU **5.1.0** (o 2.9.1 é mais rápido, mas está sem correções de
  segurança há anos).
- A partir do 6.0.0 os APKs são multi-ABI, então **um** APK serve host ARM 32/64.
- Use a variante **ARM** (guest). A variante x86 existe e é mais madura, mas
  emula x86 — não é o que o KolinOS usa (§7).
- Ative **MTTCG** (o app ARM só permite em host 64-bit — ver o `if` no
  `LimboEmuActivity`).

### 2.3 Acesso à tela

O Limbo desenha por **VNC** (modo serviço, roda em background) ou **SDL** (só em
primeiro plano). Para o KolinOS:

- Console de texto, sem desktop: precisa de um framebuffer que o kernel dirija
  (`tty0`) **ou** de redirecionar o serial (`ttyAMA0`). Ver §4.3 — é o ponto mais
  delicado da rota arm64.
- FASE 7 (desktop "Corvo Glass"): possível, mas sobre TCG puro o desktop arm64
  será **muito** lento. Não é meta de primeira validação.

---

## 3. Requisitos do guest (o que o KolinOS já tem)

- **Kernel**: `linux-image-arm64` — já presente no rootfs (o estágio 85 exige).
- **initrd**: `initramfs-tools` — já presente.
- **Rootfs**: ext4 com `/etc/fstab` por UUID — já gerado pelo estágio 85.
- **Usuário/senha**: o `kolinos login:` já existe.
- **Drivers virtio**: o kernel Debian arm64 traz `virtio_blk`, `virtio_pci`,
  `virtio_net`, `virtio_gpu` (o essencial no initrd). Para `-M virt` **isto é
  obrigatório**, porque a placa virt não tem IDE.
- **Serial**: a placa `virt` usa `ttyAMA0` como console serial.

O que **não** existe e precisa ser criado: um disco em formato que o Limbo
aceite, sem ESP/GRUB. Ver §5.

---

## 4. Requisitos de boot

O Limbo monta a linha de comando do QEMU e **suporta boot direto por kernel**:

```java
// VMExecutor.java
addCpuBoardOptions(paramsList);   // -smp, -M (se Machine Type != "Default"), -cpu
kernel  != "" -> -kernel  <file>
initrd  != "" -> -initrd  <file>
append  != "" -> -append  "<cmdline>"
extraParams != "" -> acrescentados crus ao final da linha
```

### 4.1 As três rotas, em ordem de viabilidade

| Rota | Como | Firmware | Situação |
|---|---|---|---|
| **A. Boot direto (recomendada)** | `-M virt -cpu cortex-a53 -kernel vmlinuz -initrd initrd.img -append "root=/dev/vda console=ttyAMA0"` | nenhum | é a rota com menos peças; usa o kernel/initrd do KolinOS |
| **B. UEFI aarch64** | igual à imagem da FASE 8, com AAVMF no pflash via *Extra params* | AAVMF externo | reaproveita a ESP, mas exige firmware que o Limbo não traz |
| **C. x86** | compilar KolinOS `amd64` e usar BIOS legado | SeaBIOS embutido | rota mais documentada do Limbo, mas exige portar o build (§7) |

### 4.2 Campos do Limbo a preencher (rota A)

| Campo do Limbo | Valor | Por quê |
|---|---|---|
| Machine Type | `virt` | `versatilepb` (padrão) é ARM 32-bit e não roda kernel aarch64 |
| CPU | `cortex-a53` (ou equivalente 64-bit; `max` serve) | o padrão do `virt` é `cortex-a15`, ARMv7 |
| RAM | 1024 MiB | abaixo de ~512 MiB o Debian sofre |
| Kernel Image | `vmlinuz-…` extraído do rootfs | habilita boot direto |
| Initrd Image | `initrd.img-…` extraído do rootfs | necessário para achar a raiz |
| Append | `root=/dev/vda console=ttyAMA0` | raiz no disco virtio e console serial |
| Disks | o disco com o rootfs | ver §5 |

> **Atenção:** se o dropdown **Machine Type** da sua build não listar `virt`, ou o
> dropdown de CPU não listar nenhuma opção 64-bit, use o campo **Extra params**
> para passar `-M virt -cpu cortex-a53` diretamente — o Limbo acrescenta esses
> argumentos crus à linha de comando.

### 4.3 Console: o ponto frágil

`-M virt` entrega serial em `ttyAMA0`, não um console de PC. Duas saídas:

- `console=ttyAMA0` e capturar o serial. O Limbo não expõe um campo de "arquivo
  de serial"; se o VNC não mostrar a saída, é preciso passar
  `-serial file:…` junto das *Extra params* (isso desloca o serial padrão do
  QEMU — teste).
- `console=tty0` com framebuffer virtual (`virtio-gpu`/`ramfb`) para ver o texto
  no VNC.

Qual das duas funciona depende da build do Limbo. **Teste as duas; não presuma.**

### 4.4 Som, rede, snapshot

- **Som**: irrelevante para boot. Deixe desligado.
- **Rede**: modo **user/NAT**. O wiki do Limbo é contraditório sobre TAP ("não
  suportado" em uma página, disponível em outra); na prática TAP exige
  dispositivo TAP e **root no Android**. Sem root, user/NAT.
- **Snapshot/estado**: exige disco **QCOW/QCOW2**. Um `IMG` cru não segura
  estado. Se quiser suspender/retomar, use qcow2.

---

## 5. Requisito de build: o disco para o Limbo

O artefato da FASE 8 é um disco **GPT com ESP + root ext4**, pensado para UEFI.
Para a rota A isso é desnecessário — o bootloader é pulado. O que o Limbo precisa
é um **disco simples**:

- uma única partição (ou disco inteiro) **ext4**, com o rootfs dentro;
- `/etc/fstab` apontando para `/dev/vda` (ou por UUID), não para a partição 2 do
  esquema GPT;
- tamanho compatível com TCG: cada read/write é emulado. Vale um perfil enxuto
  (sem desktop).

O instalador já quase cobre isso: `install/targets/disk.sh` escreve o rootfs em um
dispositivo, mas **não cria tabela de partição** (por design, FASE 10). Para o
Limbo é preciso um passo novo — algo como:

```sh
# no host, fora do Limbo
truncate -s 3G kolinos-limbo.img
mkfs.ext4 -F -L KOLINOS kolinos-limbo.img
# popula a raiz com o rootfs (sem mount, como o estágio 85 já faz)
```

e ajustar o fstab para `/dev/vda`.

Ainda: **o kernel e o initrd saem do rootfs para o armazenamento do Android**,
porque o Limbo os recebe por arquivo (`-kernel`/`-initrd`), não por partição
`/boot`.

### 5.1 Perfil de dispositivo

Um perfil novo, por exemplo `config/devices/limbo-aarch64.conf`, com
`KOLIN_DEVICE_KIND=vm`, para gerar o disco no formato da §5 e documentar a
cmdline. O `KOLIN_DEVICE_*` já existe para esse tipo de variação (ver
`config/devices/*.conf`).

---

## 6. Requisitos de hardware emulado

| Componente | Opções do Limbo | Para o KolinOS |
|---|---|---|
| CPU | `arm926/946/1026` (32-bit), ou `-cpu` livre via Extra params | **`cortex-a53`/`max`** — as opções prontas são 32-bit |
| Máquina | `versatilepb` (padrão), ou `-M` livre | **`virt`** |
| Vídeo | `std`, `cirrus`, `vmware`, `qxl` | para `virt`, prefira `virtio-gpu`; `-M virt` não tem VGA de PC |
| Rede | `rtl8139`, `ne2k_pci`, `e1000`, `pcnet`, `i82551`, `virtio` | **`virtio`** (a placa virt não tem PCI IDE/Realtek clássico) |
| Disco | IDE, CDROM, floppy, **SD card** (imagem) | disco **virtio**; o Limbo expõe SD card no app ARM |
| Som | `sb16`, `ac97`, `hda`, … | desligado |

> **Ponto crítico:** `-M virt` é uma máquina **virtio-only**. Ela não tem IDE,
> nem VGA de PC, nem Realtek. Se o Limbo anexa os discos como IDE por padrão, o
> guest **não verá o disco**. Provavelmente será preciso passar
> `-drive file=…,if=virtio,format=raw` nas *Extra params*. **Confirme isso na sua
> build antes de tentar** — é a causa mais provável de "não acha a raiz".

---

## 7. Rota alternativa: KolinOS x86

Se a rota arm64 travar, a rota x86 é a mais madura do Limbo e a mais próxima de
"funciona" (BIOS legado + IDE + VGA padrão, tudo que o Limbo já faz bem).

O `build.sh` já aceita `--arch amd64`, mas o resto do caminho não está pronto:
o estágio 85 fixa `linux-image-arm64`, `grub-mkstandalone -O arm64-efi` e
`BOOTAA64.EFI`. Um alvo x86 exige `linux-image-amd64`, `x86_64-efi` /
`i386-pc` e `BOOTX64.EFI`.

Requisitos concretos, se você seguir por aqui:

1. Perfil `config/devices/limbo-x86.conf` com `--arch amd64`.
2. Generalizar o estágio 85 (kernel, alvo do GRUB, nome do `.EFI`) — hoje os
   literais arm64 estão no estágio.
3. Escolher BIOS legado (`grub-pc` + MBR) **ou** UEFI (OVMF externo). O Limbo não
   traz OVMF; o Debian fornece `qemu-efi-amd64`.
4. Disco `IMG`/`QCOW2` com IDE (aqui IDE é o certo, ao contrário da rota arm64).
5. Cmdline `console=tty0 console=ttyS0,115200`.

---

## 8. Como testar

### 8.1 No host, antes do aparelho

A rota A pode ser ensaiada **inteira** com o `qemu-system-aarch64` do host — é o
mesmo QEMU que o Limbo roda:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a53 -m 1024 \
    -kernel vmlinuz-… -initrd initrd.img-… \
    -append "root=/dev/vda console=ttyAMA0" \
    -drive file=kolinos-limbo.img,if=virtio,format=raw \
    -nographic
```

Se o guest não chega a `kolinos login:` aqui, **não chegará no Limbo**. Este é o
teste que separa problema de guest de problema de app.

| Verificação | Onde | Comando |
|---|---|---|
| Kernel/initrd existem | host | `ls rootfs/boot/vmlinuz-* rootfs/boot/initrd.img-*` |
| Disco é ext4 válido | host | `file kolinos-limbo.img` |
| Driver virtio no initrd | host | `lsinitramfs initrd.img-… \| grep virtio` (pacote `initramfs-tools-core`) |
| Boot completo | host | comando acima, esperar `login:` |
| ISO é bootável? | host | `xorriso -indev <iso> -report_el_torito plain` (**não** tem El Torito — §9) |

### 8.2 No aparelho

1. Copie o `.img`/`.qcow2`, o kernel e o initrd para o armazenamento interno.
2. No Limbo: Machine Type `virt` (ou Extra params `-M virt -cpu cortex-a53`),
   RAM 1024 MiB, MTTCG ligado, disco no campo de disco, kernel/initrd/append
   conforme §4.2.
3. Inicie e acompanhe pelo VNC (ou `--allow-external-vnc` para headless).
4. Ajuste o `if=virtio` via Extra params se o disco não aparecer (§6).

---

## 9. Limites (o que não é verdade)

- **"O Limbo não tem arm64" é falso.** Tem (`libqemu-system-aarch64.so`). O que
  falta é vir configurado para aarch64 — o padrão é 32-bit.
- **Aceleração: não conte com ela.** KVM depende de `/dev/kvm`, indisponível no
  Android comum. É TCG puro: boot em minutos, desktop lento.
- **A ISO do KolinOS não inicializa em lugar nenhum.** Ela é um *carrier de
  dados* (`xorriso -as mkisofs` sem El Torito): contém rootfs, fonte e
  instalador. **Não** serve como CD-ROM de boot no Limbo nem em PC.
- **TAP exige root no Android.** Sem root, user/NAT.
- **UEFI exige firmware externo** (AAVMF para aarch64, OVMF para x86). O Limbo
  não traz nenhum.
- **`proot-distro` é outra história.** É a rota principal do KolinOS no Termux
  (guest arm64 sem emulação de PC) e não tem relação com o Limbo.

---

## 10. Checklist para o primeiro boot no Limbo (rota A)

- [ ] Limbo 6.0.0 (QEMU 5.1.0), variante ARM, MTTCG ligado.
- [ ] Disco ext4 com o rootfs e fstab em `/dev/vda`, em `IMG` ou `QCOW2`.
- [ ] `kernel`/`initrd` do rootfs extraídos para o Android.
- [ ] Machine Type `virt` (ou `-M virt` via Extra params).
- [ ] CPU 64-bit (`cortex-a53`/`max`).
- [ ] Disco anexado como **virtio** (senão o guest não vê a raiz).
- [ ] Cmdline com `root=/dev/vda` e console (`ttyAMA0` ou `tty0`).
- [ ] Validado em `qemu-system-aarch64` no host **antes** do aparelho.
- [ ] Perfil `limbo-aarch64.conf` criado para reproduzir o disco.

Enquanto os itens não estiverem fechados, o que aparece no Limbo não é "KolinOS
rodando": é erro de boot. As §§5, 5.1 e 6 são o trabalho de build que ainda falta.
