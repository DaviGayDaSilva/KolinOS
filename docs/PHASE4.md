# FASE 4 — Build reproduzível

Objetivo: **o mesmo commit produz o mesmo artefato**, byte a byte, mesmo rodando
em dias diferentes. A construção de um rootfs é afetada por várias fontes de
não-determinismo; esta fase ataca cada uma delas e prova o resultado com um
teste que constrói duas vezes e compara o SHA-256.

## As fontes de não-determinismo

| Fonte | Problema | Solução |
|---|---|---|
| Espelho Debian | `trixie` muda todo dia — versões diferentes | `--snapshot` fixa o `snapshot.debian.org` |
| Validade do Release | o snapshot tem `Valid-Until` no passado | `[check-valid-until=no]` nos `sources.list` |
| Data/hora | `mtime` de cada arquivo para no tar | um `epoch` fixo (`kolin_build_epoch`) |
| Ordem dos arquivos | `readdir` não é ordenado | `find` + `LC_ALL=C sort -z` no `tar` |
| **atime** | o `tar` GNU grava a hora de leitura, que muda a cada run | formato `pax`, `delete=atime,delete=ctime` |
| Nomes de dono | uid/gid podem variar | `--owner=0 --group=0 --numeric-owner` |
| Senha (`/etc/shadow`) | `chpasswd` usa salt aleatório | `openssl passwd -6 -salt kolinos ...` + `usermod -p` |
| `aux-cache` do ldconfig | grava números de inode, únicos por build | removido no estágio 70 (é só um cache) |
| `BUILD_DATE` em `/etc/kolinos/version` | `date` corrente | `kolin_iso_utc "$KOLIN_BUILD_EPOCH"` |
| Metadados do dpkg | `md5sums` guarda `mtime` de arquivos-skeleton | `path-exclude` p/ `/etc/default/rcS` |
| Data do ISO | xorriso grava a hora da build | `--set_all_file_dates` |
| Data nos manifests | `date` corrente | reaproveita o epoch |

## O epoch fixo

`KOLIN_BUILD_EPOCH` é um único timestamp Unix usado em **tudo**: mtime dos
arquivos do rootfs, cabeçalhos do `tar`, datas do ISO, `METADATA.txt` e
`MANIFEST`. Por padrão ele vem da **data do commit `HEAD`** (`git log -1 --format=%ct`),
não do relógio. Assim:

- reconstruir o mesmo commit dias depois dá o mesmo resultado;
- um `git commit` novo muda o epoch — é o Esperado.

Isso tem uma sutileza honesta: **enquanto a árvore estiver suja (não commitada),
o epoch não muda**, porque depende só do commit. Para congelar completamente,
defina `KOLIN_BUILD_EPOCH` explicitamente em `VERSION` e faça o commit.

## O snapshot Debian

Sem snapshot, `debootstrap` e o APT baixam o que estiver no espelho naquele
momento — dois builds em dias diferentes instalam versões diferentes.

Com `--snapshot`, os repositórios são reescritos para o `snapshot.debian.org`:

```
http://snapshot.debian.org/archive/debian/20250901T000000Z
http://snapshot.debian.org/archive/debian-security/20250901T000000Z
```

O sufixo `-updates` fica no arquivo principal (o snapshot mescla `trixie` e
`trixie-updates` no mesmo carimbo de tempo) e `trixie-security` vem do arquivo
de segurança.

## Como usar

```bash
# Build reprodutível normal (usa a data do commit como epoch):
sudo bash build.sh --snapshot 20250901T000000Z

# Atalho para a data fixada em VERSION:
sudo bash build.sh --reproducible

# Congelar o epoch explicitamente (por exemplo, para um release):
sudo bash build.sh --reproducible --epoch 1790000000

# Teste de aceitação: constrói DUAS vezes e compara os arquivos.
sudo bash scripts/host/verify-reproducible.sh --snapshot 20250901T000000Z
```

Compare também à mão:

```bash
sha256sum output/kolinos-1.0.0-corvo-arm64.tar.xz
```

## Limites (honesto)

- Reproduzir o **rootfs** é o que esta fase garante. A partir de FASE 5 (pacotes
  próprios) o próprio `dpkg-deb` precisa das mesmas salvaguardas — a
  infraestrutura de epoch já está pronta para ser reaproveitada.
- Repro\dutibilidade **bit-a-bit** exige o **mesmo Debian suite e a mesma
  arquitetura**. O `built on` em `METADATA.txt` registra o host, mas o rootfs
  em si não depende dele (é cross-build via QEMU).
- Sem `--snapshot`, o build continua funcionando, mas não é reprodutível — o
  `METADATA.txt` marca isso explicitamente.
- Rodar no Termux (proot) não muda isto: o build continua sendo feito num host
  Linux com root; proot não contribui para reprodutibilidade.

## O que NÃO é determinístico (e não tentamos forçar)

- O binário `qemu-aarch64-static` do host: ele é removido do rootfs antes do
  empacotamento, então não entra no hash.
- O conteúdo de `/var/lib/apt/lists` (limpo no estágio 70).
- Logs, histórico de shell e `machine-id` (limpos no estágio 70).
