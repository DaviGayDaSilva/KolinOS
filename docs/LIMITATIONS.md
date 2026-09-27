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

## 6. O que só pode ser feito em **hardware real** (Fase 10)

- Kernel + device tree para o aparelho.
- Interface gráfica nativa (sem termux-x11/VNC).
- Instalador `.img` de disco.
- Testes de bateria, aquecimento, drivers.

---

## Resumo visual

| Recurso | Termux | proot | root | kernel próprio | bootloader livre |
|---|:--:|:--:|:--:|:--:|:--:|
| Rodar KolinOS (userland) | ✅ | ✅ | ✅ | ✅ | ✅ |
| APT/DPKG | ✅ | ✅ | ✅ | ✅ | ✅ |
| Instalar pacotes | ✅ | ✅ | ✅ | ✅ | ✅ |
| GUI (via termux-x11/VNC) | ✅ | ✅ | — | nativo | nativo |
| `chroot` real | ❌ | ❌ | ✅ | ✅ | ✅ |
| `mount`/`mknod` | ❌ | ❌ | ✅ | ✅ | ✅ |
| systemd/init real | ❌ | ❌ | parcial | ✅ | ✅ |
| Drivers de hardware | ❌ | ❌ | ❌ | ✅ | ✅ |
| Boot do aparelho | ❌ | ❌ | ❌ | ✅ | ✅ |

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
- **Não inicializa** em PC nem em celular. Uma ISO bootável exige kernel +
  bootloader e pertence à Fase 10.
