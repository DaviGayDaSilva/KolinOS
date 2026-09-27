# FASE 5 — Pacotes próprios

**Objetivo:** parar de copiar arquivos à mão para dentro do rootfs e passar a
entregar o software KolinOS como **pacotes `.deb` de verdade**, instalados pelo
próprio APT/DPKG. É o que torna o KolinOS uma distribuição e não apenas um
Debian com arquivos extras.

Antes desta fase, o estágio `60-postinstall.sh` copiava
`tools/kolinos-info` para `/usr/local/bin`. Agora esses arquivos pertencem a um
pacote, têm versão, dependências e checksums registrados no dpkg.

---

## 1. Metodologia de empacotamento

O host de desenvolvimento pode ser um Termux (sem root, sem `debhelper`), então
o build **não** depende de `dpkg-buildpackage`/`debuild`/`sbuild`. Ele usa apenas
`dpkg-deb`, que existe tanto no Debian quanto no Termux (via `dpkg`):

```
receita (debian/control + debian/changelog + prebuild.sh)
        │
        ├── prebuild.sh   monta o payload em uma árvore limpa
        │
        └── build-deb.sh  troca debian/ → DEBIAN/, gera md5sums e
                          Installed-Size, e chama:
                          dpkg-deb --root-owner-group -Zxz --build
```

Detalhes do `scripts/host/build-deb.sh`:

- **`debian/` → `DEBIAN/`**: receitas usam o nome familiar em minúsculas
  (como `dpkg-source`); o `dpkg-deb` exige `DEBIAN/` em maiúsculas em tempo de
  build. A árvore `DEBIAN/` é recriada do zero, inclusive para contornar bits
  `setgid` herdados de checkouts com diretórios graváveis por grupo.
- **`md5sums` automático**: gerado a partir do payload real, com exatamente
  **dois espaços** entre o hash e o caminho — é o que o `dpkg -V` espera (com um
  espaço só, ele aborta com `control file 'md5sums' ... is missing value
  separator`).
- **`Installed-Size` automático**: calculado com `du`, para o autor não esquecer.
- **`@KOLIN_DEB_ARCH@`**: substituído pela arquitetura do alvo (`arm64`), então
  a receita é a mesma em qualquer arquitetura.
- **Reprodutibilidade**: `SOURCE_DATE_EPOCH` carimba todos os arquivos e
  `--root-owner-group` zera o dono. O mesmo commit gera `.deb` byte a byte
  idênticos (verificado: SHA-256 igual entre duas construções).

Limitações desta escolha (documentadas de propósito):

- Sem `debhelper`, não há `dh_install`, `dh_installdocs`, `dh_*` etc. O
  `prebuild.sh` faz esse papel. Para pacotes com **código compilado** de
  verdade, `debhelper`/`sbuild` continuam sendo o caminho recomendado no futuro.
- Sem `fakeroot`, o `build-deb.sh` precisa rodar como root no host para os
  metadados de dono. No Termux, usa-se `--root-owner-group`, que não exige root.
- Sem `lintian` no host, a validação de política Debian é feita pelo
  `verify-rootfs.sh` (dpkg-query + `dpkg -V`), não por lintian.

---

## 2. Os três pacotes

Receitas em `packages/custom/<nome>/`. Cada uma tem `debian/control`,
`debian/changelog` e `prebuild.sh`.

| Pacote | O que faz | Depende de |
|---|---|---|
| `kolinos-base` | Metapacote que **marca** o sistema como KolinOS e junta os componentes. Deixa `/etc/kolinos/target`. | `kolinos-tools`, `kolinos-branding`, `sudo`, `ca-certificates`, `bash-completion` |
| `kolinos-tools` | Ferramentas de linha de comando em `/usr/bin`: `kolinos-info`, `kolinos-version`, `apt-kolinos`. | `bash` |
| `kolinos-branding` | Identidade visual em `/etc/kolinos/branding`: `logo.txt`, `logo-small.txt`, `palette.txt` e `/etc/kolinos/colors.sh`. | `bash` |

Os arquivos vêm do repositório (fonte única): `tools/*`,
`config/branding/*`. O `prebuild.sh` apenas os instala na árvore do pacote —
nada é duplicado no projeto.

`kolinos-base` é um metapacote: não tem arquivos além do marcador, existindo
para que `apt install kolinos-base` traga o sistema completo e para que
`dpkg-query -W kolinos-base` sirva de teste de "sou KolinOS?".

---

## 3. Como os pacotes entram no rootfs (estágio 35)

`build/stages/35-packages.sh` roda **depois** dos pacotes Debian (30) e **antes**
da identidade (40):

1. Chama `scripts/host/build-deb.sh` para construir os três `.deb` com o epoch
   do build (reprodutível).
2. Chama `repo/scripts/build-repo.sh --unsigned`, que monta um repositório APT
   local (`pool/` + `dists/corvo/main/binary-<arch>/`) a partir desses `.deb`.
3. Copia o repositório para dentro do rootfs (em `/var/tmp/kolinos-repo`) e
   aponta o APT para ele via `file://` — sem rede.
4. `apt-get install -y --no-install-recommends kolinos-base`: dependências
   entre os pacotes KolinOS e destes com pacotes Debian são resolvidas **de
   verdade**, pelo mesmo APT que o usuário final vai usar.
5. Grava `output/kolinos-packages.txt` com os pacotes instalados (versão e
   arquitetura) e remove o repositório/`sources.list` temporários.

Por que `file://` e não copiar os arquivos: o objetivo da fase é justamente
provar que o caminho **APT → dpkg** funciona. Um `dpkg -i` manual não testaria
resolução de dependências nem o repositório.

O `sources.list` de build usa `[trusted=yes]` porque esse repositório é
temporário e não assinado — ele é criado e consumido dentro do mesmo build e
nunca sai da máquina. O repositório **publicado** (FASE 9) é assinado e usa
`Signed-By`. O verificador garante que o repositório de build **não vaza** para
a imagem final.

Para builds que não devem ter os pacotes KolinOS (por exemplo, um teste offline
mínimo), use `--no-custom-debs`. Nesse caso o estágio 40 volta a instalar a
identidade visual manualmente, para o sistema seguir bonito.

---

## 4. Repositório APT próprio (`repo/`)

O `repo/scripts/build-repo.sh` foi endurecido nesta fase para ser
**determinístico** e **multi-arquitetura**:

- Reconstrói `repo/public/` do zero, então um `.deb` removido não fica no índice.
- Indexa apenas `.deb` da arquitetura do alvo (mais `Architecture: all`), para
  um pacote de outra arquitetura não vazar para o `Packages`.
- `gzip -9n` (sem mtime embutido) e `xz`; `Release` com `Date` em **RFC 1123**
  (`Sun, 27 Sep 2026 17:00:44 UTC`). Um epoch cru faz o APT rejeitar o `Release`.
- Aceita `--arch` e `KOLIN_REPO_PUB`, então serve tanto para o repositório local
  do build quanto para o repositório publicado.

Reprodutibilidade verificada: duas construções produzem a mesma árvore
(SHA-256 agregado idêntico) e o mesmo `Release`.

A publicação (GitHub Pages / servidor) e a ativação por padrão continuam na
FASE 9.

---

## 5. Ferramenta de repositório: `apt-kolinos`

`tools/apt-kolinos` (dentro do pacote `kolinos-tools`) liga e desliga o
repositório KolinOS no sistema instalado:

```sh
apt-kolinos status     # mostra se o repositório está ativo
sudo apt-kolinos enable
sudo apt-kolinos disable
```

Ela move `/etc/apt/sources.list.d/kolinos.sources{.disabled,}`, o mesmo arquivo
que o estágio 20 instala (desabilitado por padrão). Enquanto
`KOLIN_APT_REPO_URL` em `VERSION` estiver vazio, habilitar não aponta para lugar
nenhum — o campo `URIs` fica vazio de propósito, e a fase 9 preenche.

---

## 6. Testando

No host (precisa de root e, para `arm64` em x86_64, de `qemu-user-static` ou
`proot`):

```sh
# 1. só os pacotes + repositório, em um rootfs já existente (rápido)
sudo bash build.sh --only 35

# 2. build completo
sudo bash build.sh --reproducible

# 3. verificação (inclui o bloco "Pacotes próprios (FASE 5)")
sudo bash scripts/host/verify-rootfs.sh
```

O verificador checa:

- `kolinos-base`, `kolinos-tools` e `kolinos-branding` instalados (com versão e
  arquitetura);
- `dpkg -S /usr/bin/kolinos-info` (o arquivo pertence ao pacote, não foi copiado);
- `dpkg -V kolinos-tools` limpo (checksums conferem);
- `apt-kolinos` presente e respondendo;
- `kolinos.sources.disabled` presente (repositório remoto inativo);
- o repositório temporário de build **não** está no rootfs.

Para inspecionar um pacote sem instalar:

```sh
dpkg-deb -I packages/custom/debs/kolinos-base_1.0.0-1_arm64.deb   # metadados
dpkg-deb -c packages/custom/debs/kolinos-tools_1.0.0-1_arm64.deb  # conteúdo
```

---

## 7. Limitações (Termux vs proot vs root)

- **Construir os `.deb`**: funciona no Termux sem root — é só `dpkg-deb`. Se as
  ferramentas de host não existirem, instale `dpkg` no Termux (`pkg install
  dpkg`). Aqui não há código compilado, então a arquitetura do pacote é apenas
  um campo.
- **Instalar dentro do rootfs via APT**: no Termux isso acontece dentro do
  `proot-distro`, onde `apt` e `dpkg` são os do próprio rootfs — funciona sem
  root. No host x86_64 com alvo arm64, o build precisa executar binários arm64
  (`apt`, `dpkg`); isso exige `binfmt_misc` + `qemu-user-static`, ou `proot`
  quando `binfmt_misc` não está disponível. Sem nenhum dos dois, o estágio 35
  falha com mensagem explícita.
- **Assinar o repositório** (`make-gpg-key.sh`, FASE 9) dispensa root, mas a
  chave privada precisa ser protegida.
- Nada nesta fase exige kernel próprio, bootloader ou root no Android.

---

## 8. Próximos passos (não desta fase)

- Pacotes com **código compilado** (aí sim `debhelper`/`sbuild`, builds por
  arquitetura) e `kolinos-desktop` na FASE 7.
- `apt-kolinos` apontando para o repositório publicado e assinado (FASE 9).
- Instalador que registre o repositório no primeiro boot (FASE 6).
