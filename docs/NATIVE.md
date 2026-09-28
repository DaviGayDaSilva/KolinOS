# Código nativo (FASE 8.5)

Até a FASE 8 o KolinOS era **100% shell**. Isso não era uma escolha de design:
era uma consequência de o host de build não ter nenhum compilador cruzado
instalado, o que tornava impossível produzir código nativo para ARM64. Este
documento registra a correção e o que ela adiciona.

## Por que C

Shell é a escolha certa para **orquestração** — debootstrap, apt, chroot,
parted, mke2fs. É como Debian, Alpine e Arch constroem suas imagens, e o
KolinOS segue o mesmo caminho: os scripts em `build/stages/` continuam sendo o
sistema de build.

O que shell é a escolha **errada** é para as ferramentas que rodam *dentro* do
sistema, no aparelho do usuário. Cada `$(awk ...)`, cada `$(sed ...)`,
cada `dpkg-query` custa um `fork` + `exec` e uns poucos MB de RSS. Em um celular
ARM64 com 2 GB de RAM, dentro do proot, isso é caro — e é exatamente o
público-alvo definido no requisito 8.

Os binários em C:

- não precisam de interpretador (funcionam com `/bin/sh` quebrado);
- são ligados **estaticamente**, então não dependem do `ld.so` nem da libc do
  rootfs — funcionam em proot e em sistema degradado;
- leem `/proc` e `/sys` diretamente, sem `fork`.

## O que existe

| Fonte | Linhas | Função |
|---|---|---|
| `src/include/kolinos.h` | ~90 | Declarações compartilhadas; sem dependências fora da libc |
| `src/common/common.c` | ~140 | Cores, leitura de arquivos, parsing de `/proc`, tamanhos |
| `src/kolinos-hw/kolinos-hw.c` | ~330 | Hardware: CPU, núcleos, big.LITTLE, memória, swap, discos, térmico, carga |
| `src/kolinos-fetch/kolinos-fetch.c` | ~330 | Resumo do sistema, lendo `/etc/os-release` e `/etc/kolinos/` de verdade |

Total: ~890 linhas de C. Dependência externa: **nenhuma**, só libc.

### `kolinos-hw`

Faz o que `uname`, `nproc`, `free`, `df`, `uptime` e `cat /sys/...` fariam, em
um único processo. Detalhes que valem registrar:

- **big.LITTLE**: conta os `CPU part` distintos em `/proc/cpuinfo` para
  distinguir um SoC real (2 clusters) de uma VM homogênea (1), sem embutir
  nenhum número de part conhecido.
- **Discos**: filtra *bind mounts de arquivo* (`/etc/hosts`,
  `/dev/termination-log`) e desduplica por `st_dev`. Sem isso, um container
  reporta 15 "discos" que são o mesmo sistema de arquivos — bug encontrado
  durante o teste, não em teoria.
- **Térmico**: lê `/sys/class/thermal` (a única temperatura que um celular
  expõe sem root) e descarta valores fisicamente impossíveis em vez de
  inventar.
- **`--json`**: uma linha, chaves estáveis, para consumo por script.

### `kolinos-fetch`

Lê a identidade do sistema **dos arquivos reais**, não compilada:

- `/etc/os-release` → `NAME`, `VERSION_ID`, `ID`, `ID_LIKE`;
- `/etc/kolinos/version` → `DEBIAN_SUITE`, `BUILD_DATE`;
- `/etc/kolinos/branding/logo.txt` → o logo.

Vantagem prática: **um único binário** reporta os valores corretos de qualquer
build, e mudar o codename não exige recompilar.

- **Pacotes**: lê `/var/lib/dpkg/status` direto em vez de chamar `dpkg-query`.
- **Usuário**: lê `/etc/passwd` direto. `getpwuid()` foi descartado porque
  puxa o NSS da glibc em runtime, o que **não funciona** em binário estático —
  o linker emite um aviso exatamente sobre isso.
- **Hostname**: prefere `/etc/hostname`, porque sob proot a syscall devolve o
  nome do kernel Android.

## Como compilar

No host de build (Debian/Ubuntu):

```sh
sudo apt-get install gcc-aarch64-linux-gnu
make                    # binários ARM64 estáticos em build/native/
```

Outros alvos:

```sh
make test               # compila para o host e executa os testes
make check-syntax       # só diagnóstico do compilador, sem linkar
make CROSS= STATIC=0    # build nativo do host, dinâmico
make clean
```

## Como testar

```sh
make test                       # executa de verdade e verifica ausência de ANSI sem tty
qemu-aarch64-static -L /usr/aarch64-linux-gnu build/native/kolinos-hw
```

O segundo comando executa o binário ARM64 em um host x86 via emulação; foi
assim que a arquitetura foi confirmada (`Máquina: aarch64`).

## Integração com o build

- `build/stages/32-native.sh` compila para ARM64, roda **antes** do estágio 35,
  e **verifica a arquitetura** do resultado (`readelf -h`) para que um binário
  nativo não seja empacotado como arm64 por engano.
- `packages/custom/kolinos-tools/prebuild.sh` copia `build/native/*` para
  `/usr/bin` do pacote, junto com os utilitários shell.

## Limitações

- **O compilador cruzado não existe no Termux.** `gcc-aarch64-linux-gnu` é
  pacote Debian; não há equivalente no Termux. O estágio 32 detecta a ausência
  e **pula com mensagem clara** — o build continua e os utilitários shell
  permanecem como implementação única. Não é falha do build.
- Isso é uma dependência de **host**, não do sistema gerado. O rootfs final
  não precisa de compilador.
- Os utilitários shell (`kolinos-info`, etc.) **não foram removidos**: eles são
  o fallback documentado. `kolinos-fetch` é o substituto nativo de
  `kolinos-info`, com os mesmos campos.
- Não há aplicativos gráficos em C ainda; a interface (FASE 7) continua em
  scripts que chamam `openbox`, `picom`, `rofi`, `foot` e `feh`.
