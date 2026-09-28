# KolinOS — Limitações por ambiente

Este documento separa, com honestidade, **o que funciona onde**. Se uma solução
exige root, ela é apresentada como exigindo root — nunca como se funcionasse sem.

---

## 1. Termux (Android, app normal)

Funciona **sem root**:

- `pkg`, shell, compiladores (clang), Python, Git.
- `proot-distro` para rodar um userland Linux completo (Debian, Ubuntu, …).
- Construir/editar o código-fonte do KolinOS.
- Rodar o **rootfs KolinOS** via proot-distro (é o caminho principal da Fase 1–6).

Não funciona / limitações:

- Não há `chroot` real sem root.
- Sem acesso a dispositivos de hardware completos.
- Alguns `mount` e operações de sistema são negados pelo SELinux/seccomp do
  Android.
- `sudo` dentro do proot é limitado (não é root real no kernel).

---

## 2. proot (usado pelo proot-distro)

Como funciona: o `proot` intercepta chamadas de sistema (`ptrace`) e traduz
caminhos, permitindo um "chroot de mentira" **sem root**.

Funciona:

- Rodar todo o userland Debian (APT, DPKG, serviços em foreground).
- Instalar pacotes, criar usuários, personalizar o sistema.
- Desenvolver e validar a identidade do KolinOS (Fases 2–6).

Limitações reais:

- **Desempenho:** toda syscall passa pela tradução → mais lento.
- **Sem kernel próprio:** `uname` mostra o kernel do Android (host).
- **Sem init/systemd completo:** o proot-distro inicia um shell; gerenciamento de
  serviços (systemd, `service`) não funciona de verdade.
- Alguns recursos de `apt`/`dpkg` que dependem de `mknod`, `setuid` real ou
  `mount` podem falhar; contornamos com configurações específicas.
- Nested proot não é suportado (não rodar proot dentro de proot).

---

## 3. O que exige **root** (no Android ou no host)

- `chroot` verdadeiro.
- `mount`/`umount`, `mount -t proc`, `bind mounts`.
- `mknod` para criar dispositivos.
- Modificar o kernel, módulos, `sysctl` do sistema.
- `debootstrap` rodando diretamente **no Android** (ele quer `mount`, `mknod`;
  por isso o build cross-arch é feito em host Linux ou com `--foreign` + QEMU).

KolinOS evita depender de root no fluxo de desenvolvimento: o build roda num
host Linux (onde `sudo` é normal) e o uso no celular é via proot (sem root).

---

## 4. O que exige **kernel Linux próprio**

- `init`/PID 1 de verdade, systemd, gerenciamento de serviços.
- Drivers de hardware (GPU, Wi-Fi, modem, touch, sensores).
- Controle de energia, suspensão, `sysfs` completo.
- Boot de verdade.

---

## 5. O que exige **bootloader desbloqueado** (Android)

- Substituir o sistema Android por KolinOS.
- Flashar `boot`/`system` via `fastboot`.
- Rodar um kernel próprio no aparelho.

Sem bootloader desbloqueado, o máximo que se consegue é o uso via Termux/proot.

---

## 6. Interface gráfica (Fase 7)

Um ambiente gráfico precisa de um **servidor X**. Isso não está incluído no
rootfs — é fornecido pelo ambiente.

| Cenário | GUI funciona? | Como |
|---|:--:|---|
| Termux + proot | ✅ com ressalvas | app **Termux:X11** + pacote `termux-x11`; `DISPLAY=:0 kolinos-session` dentro do proot |
| proot sem X | ❌ | não há display; use o sistema em modo texto |
| Hardware real (kernel próprio) | ✅ | Xorg (`xserver-xorg`) ou `lightdm` |
| VNC | ✅ | `tigervnc-standalone-server` no rootfs, cliente VNC no Android |

O que muda no Termux/Android:

- **Sem GPU real:** o `picom` cai para software rendering (`llvmpipe`). O blur
  funciona, mas é mais pesado — há um perfil leve comentado em
  `config/desktop/picom/picom.conf`. Em todo caso, o vidro pode ser desligado
  sem quebrar nada (só perde o blur).
- **Sem `lightdm`:** login gráfico não roda em contêiner/proot. Ele é
  `Suggests`, apenas para hardware real. No Termux, inicie direto com
  `kolinos-session`.
- **Nada disso exige root.** Nem instalar o desktop, nem rodar a sessão dentro
  do proot. Root no Android não é usado nem presumido.
- **RAM:** com o desktop carregado, espere ~250–400 MB. Em aparelho com 2 GB ou
  menos, prefira o `tint2` desligado ou o perfil leve do picom.

---

## 7. O que só pode ser feito em **hardware real** (Fase 10)

- Kernel + device tree para o aparelho.
- Interface gráfica nativa (sem termux-x11/VNC).
- Instalador `.img` de disco.
- Testes de bateria, aquecimento, drivers.
- `lightdm` e login gráfico de verdade.

---

## Resumo visual

| Recurso | Termux | proot | root | kernel próprio | bootloader livre |
|---|:--:|:--:|:--:|:--:|:--:|
| Rodar KolinOS (userland) | ✅ | ✅ | ✅ | ✅ | ✅ |
| APT/DPKG | ✅ | ✅ | ✅ | ✅ | ✅ |
| Instalar pacotes | ✅ | ✅ | ✅ | ✅ | ✅ |
| GUI (via termux-x11/VNC) | ✅ | ✅ | — | nativo | nativo |
| Blur/vidro do tema (picom) | ✅ lento | ✅ lento | ✅ | ✅ | ✅ |
| `lightdm` (login gráfico) | ❌ | ❌ | ⚠️ | ✅ | ✅ |
| `chroot` real | ❌ | ❌ | ✅ | ✅ | ✅ |
| `mount`/`mknod` | ❌ | ❌ | ✅ | ✅ | ✅ |
| systemd/init real | ❌ | ❌ | parcial | ✅ | ✅ |
| Drivers de hardware | ❌ | ❌ | ❌ | ✅ | ✅ |
| Boot do aparelho | ❌ | ❌ | ❌ | ✅ | ✅ |

---

## Sobre executar o rootfs arm64 fora do Termux (chroot/qemu)

Ao testar o repositório APT dentro do rootfs num host x86_64, aparecem dois
limites que **não** existem no Termux — e que vale não confundir com defeito do
repositório:

- **`chroot` não executa binários arm64.** Sem uma entrada `binfmt_misc`, o
  kernel vê um ELF desconhecido. O APT não roda apenas a si mesmo: ele *executa*
  `/usr/lib/apt/methods/*`, o `dpkg` e o verificador `sqv`. Nenhum deles inicia.
  Dá para contornar com um wrapper **nativo** (`tools/host/qemu-method-wrapper.c`,
  compilado x86_64 estático) que reexecuta o helper real via
  `qemu-aarch64-static`; um wrapper shell não serve, porque o shell dentro do
  chroot também é arm64.
- **`qemu-user` não emula `execve` de binários do guest.** Rodando
  `qemu-aarch64-static -L / /bin/bash`, o `bash` funciona, mas quando ele tenta
  iniciar outro binário arm64 (`/usr/bin/dpkg-split`, por exemplo) o kernel
  recebe um ELF desconhecido e responde `Exec format error`. Consequência: o
  `dpkg` começa a desempacotar e para no `dpkg-split`. Não é falha do `.deb`.

Como resolver cada caso:

- **`binfmt_misc`** resolve os dois, mas exige `/proc/sys/fs/binfmt_misc`
  gravável — ou seja, root e um kernel que exponha o recurso. Em container isso
  costuma ser somente-leitura.
- **`proot`** resolve o exec aninhado em espaço de usuário e é o mecanismo que o
  Termux/proot-distro usa. É o caminho recomendado no celular.
- **`binfmt_misc` via systemd** (host Linux normal): `systemd-binfmt` registra o
  handler sozinho assim que `qemu-user-static` é instalado.

---

## Sobre o build cross-arch (host x86_64 → alvo arm64)


- Usa `debootstrap --foreign` + `qemu-aarch64-static`. Isso produz um rootfs
  **arm64 de verdade**, executável no celular.
- Requer `qemu-user-static` e, idealmente, `binfmt_misc` no host. Se o registro
  `binfmt` não estiver disponível, o build ainda funciona porque o binário
  estático do QEMU é copiado para dentro do rootfs e chamado explicitamente.
- É mais lento que um build nativo, mas totalmente funcional.

## Sobre a ISO gerada

- É uma ISO **carrier** (UDF/ISO9660): transporte de dados, não sistema
  inicializável. Contém o rootfs, o código-fonte, os docs e o instalador.
- **Não inicializa** em PC nem em celular.

## Sobre a imagem de disco (`.img`)

Gerada por `build.sh --with-image` (estágio `85-image.sh`).

Funciona:

- **Inicializa por UEFI**: firmware → `BOOTAA64.EFI` (GRUB) → kernel →
  initramfs → systemd. Verificado em QEMU aarch64 + EDK2/AAVMF até o prompt
  `kolinos login:`.
- Serve para: QEMU `virt`, VMs ARM64, placas ARM64 que exponham UEFI, PCs ARM64.
- Gravável com `dd` (ou `xz -d` e depois `dd`) em disco/SSD/cartão SD.

**Não** funciona:

- **Não inicializa em celular.** Android não usa UEFI: exige bootloader do
  fabricante (ABL/LK), partição `boot` com kernel assinado e **device tree**
  específica do aparelho. Gravar o `.img` no armazenamento de um celular não o
  torna inicializável. Isso é FASE 10 e depende de bootloader desbloqueado e
  kernel próprio.
- **Não inicializa em PC x86**: o bootloader é `arm64-efi`. Não há suporte
  `i386-pc` (BIOS).
- **Sem KVM**, o boot de teste é emulado (TCG): funciona, mas é lento.
- `mke2fs -d` copia a árvore mas não preserva `security.capability` de forma
  completa; o `tar.xz` preserva (`--xattrs`). Se capacidades importarem, prefira
  o `tar.xz`.
