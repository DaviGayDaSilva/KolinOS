# FASE 7 — Interface gráfica: tema "Corvo Glass"

**Objetivo:** dar ao KolinOS uma interface gráfica leve, adequada a celular, com
identidade visual própria (glassmorphism).

Status: implementado. O computador da imagem continua **mínimo** — o desktop é
opt-in (`--with-desktop`) e vive em pacotes `.deb` próprios (`kolinos-desktop`,
`kolinos-theme`), instalados via APT como qualquer outro.

---

## 1. O que foi feito

### Stack escolhido (do mais leve para cima)

| Papel | Pacote | Por quê |
|---|---|---|
| Window manager | `openbox` | ~2 MB de RAM ocioso; sem dependências de DE |
| Compositor | `picom` | é ele quem faz o vidro: blur real, cantos e sombras |
| Painel | `tint2` | painel leve com transparência real (depth 32) |
| Terminal | `xterm` | já na base; `foot`/`urxvt` suportados se instalados |
| Launcher | `rofi` | busca de aplicativos, tema próprio |
| Wallpaper | `feh` | aplica o fundo |
| Ícones | `adwaita-icon-theme` + `hicolor` próprio | fallback confiável |
| Fontes | `fonts-inter`, `fonts-jetbrains-mono` | tipografia da marca |

Não foi instalado um desktop completo (GNOME/KDE/XFCE): pesado demais para o
público-alvo. O XFCE pode ser adicionado depois por cima deste tema.

### Identidade "Corvo Glass"

Estética glassmorphism sobre fundo espacial escuro: superfícies translúcidas,
blur aplicado pelo compositor, contorno claro de 1px e sombras difusas.

Paleta em `config/branding/glass-palette.txt`, tokens em `VERSION`
(`KOLIN_GLASS_*`). Os assets são **SVG com tokens de cor** renderizados no build
por `scripts/artifacts/render-assets.sh` (usa `rsvg-convert`): mudar uma cor em
`VERSION` muda wallpaper, logo e ícones no próximo build.

Arquivos de tema:

- GTK 3 — `config/desktop/gtk-3.0/gtk.css` (o grosso do visual)
- GTK 2 — `config/desktop/gtk-2.0/gtkrc` (apps antigas; sem blur, mesma paleta)
- openbox — `config/desktop/openbox/themes/CorvoGlass/openbox-3/themerc`
- picom — `config/desktop/picom/picom.conf`
- tint2 — `config/desktop/tint2/kolinos.tint2rc`
- rofi — `config/desktop/rofi/kolinos.rasi`
- terminal — `config/desktop/xresources/KolinOS.Xresources`, `foot/kolinos.ini`
- wallpapers — `config/branding/wallpaper-mobile.svg` (1080×2400) e
  `wallpaper-desktop.svg` (1920×1080)
- emblema — `config/branding/emblem.svg` (corvo geométrico)

### Pacotes

- `kolinos-theme` — os arquivos de tema (GTK, openbox, tint2, rofi, Xresources)
  e a configuração em `/etc/xdg/kolinos`.
- `kolinos-desktop` — metapacoete: depende de openbox, picom, tint2, xterm,
  feh, rofi, xinit, fontes e `libgl1-mesa-dri`, e traz o greeter do lightdm.
- `kolinos-tools` — ganhou `kolinos-session`, `kolinos-terminal`,
  `kolinos-wallpaper`, `kolinos-launcher`.
- `kolinos-base` — `kolinos-desktop` é **Suggests**: a imagem base continua
  enxuta.

### Comandos

```sh
kolinos-session            # inicia a sessão (precisa de um servidor X)
kolinos-session --help     # explica os cenários (X real, Termux:X11, sem X)
kolinos-terminal           # terminal com o visual do tema
kolinos-wallpaper          # aplica o wallpaper (escolhe mobile/desktop)
kolinos-launcher           # launcher rofi
```

Atalhos: `Super+Enter` terminal, `Super+d` launcher, `Super+w` wallpaper,
`Super+q` fechar, `Super+←/→` áreas de trabalho.

---

## 2. LIMITAÇÕES — leia antes de tentar

O ponto central: **um ambiente gráfico precisa de um servidor X. O pacote
instala o desktop; ele não fornece o display server.** Isso depende do cenário:

| Cenário | Funciona? | O que é necessário |
|---|---|---|
| **Termux + proot (sem root)** | Sim, com ressalvas | app **Termux:X11** + pacote `termux-x11` no Termux. `DISPLAY=:0 kolinos-session` dentro do proot |
| **Hardware real (kernel próprio)** | Sim | servidor Xorg (`xserver-xorg`) ou lightdm; fase 10 |
| **proot puro, sem X** | **Não** | não há como abrir janelas; use o sistema em modo texto |
| **Blur / transparência** | Parcial no Termux | depende de GL. Com `llvmpipe` o picom fica lento; há um perfil leve comentado no fim de `picom.conf` |
| **Root necessário?** | Não para instalar/usar | Nem o APT dentro do proot nem a sessão precisam de root. Root no Android **não** é usado nem presumido |

O que **não** funciona sem root nem com root, no Termux, e por quê:

- Não há framebuffer/kernel gráfico acessível do proot; o X é sempre um servidor
  externo (Termux:X11/VNC).
- Aceleração de GPU real no X do Termux é limitada; espere software rendering.
- `lightdm` (login gráfico) não faz sentido dentro do Termux — não há como
  iniciar um display manager em um contêiner sem init/root. Ele é apenas
  `Suggests`, para hardware real.

---

## 3. Como testar

### 3.1 Sem build (só o visual, no host)

O melhor teste do *design* é rodar o tema em um X virtual e capturar a tela:

```sh
sudo apt-get install -y xvfb openbox picom tint2 xterm feh imagemagick \
    fonts-inter fonts-jetbrains-mono gtk-3-examples rofi xdotool x11-utils
bash scripts/host/preview-theme.sh output/desktop/preview-desktop.png
KOLIN_PREVIEW_GEOM=540x1200 bash scripts/host/preview-theme.sh output/desktop/preview-mobile.png
```

Sai um PNG com o tema real aplicado (blur incluído). Verifique no log
`/tmp/kolinos-preview-tint2.log` que **não** aparece `invalid option`.

### 3.2 Verificar os pacotes do tema

```sh
bash scripts/host/verify-desktop.sh
```

Confere que os `.deb` de `kolinos-theme`/`kolinos-desktop` contêm todos os
arquivos esperados e que os configs têm sintaxe conhecida (chaves do tint2,
chaves do picom). Não precisa de root.

### 3.3 Build completo com o desktop

```sh
sudo bash build.sh --force --with-desktop
sudo bash scripts/host/verify-rootfs.sh    # inclui o bloco "Desktop"
```

Instalar o desktop depois, num sistema já instalado (precisa do repositório
KolinOS ligado):

```sh
apt-kolinos enable
sudo apt-get install kolinos-desktop
```

Iniciar (no Termux, dentro do proot):

```sh
# numa aba do Termux (fora do proot):
termux-x11 :0
# dentro do proot:
DISPLAY=:0 kolinos-session
```

Em hardware real, o caminho é `lightdm` (se instalado) ou `startx` com
`~/.xinitrc` (veja `config/desktop/session/xinitrc.sample`); ambos chegam em
`kolinos-session`.

---

## 4. Armadilhas encontradas (não reintroduza)

- **Nunca empacote um arquivo que o Debian já possui.** `/etc/X11/xinit/xinitrc`
  é conffile do pacote `xinit`, e `/etc/xdg/openbox/{rc,menu}.xml` são conffiles
  do `openbox`. Colocá-los no `.deb` da KolinOS faz o dpkg abortar a
  descompactação do openbox com *trying to overwrite ... which is also in
  package kolinos-theme*. Por isso o `rc.xml`/`menu.xml` moram em
  `/etc/xdg/kolinos/openbox/` e são carregados com `openbox --config-file`; o
  `xinitrc` é apenas um exemplo (`xinitrc.sample`), não um arquivo instalado.
- **tint2 não tem `background_id =`.** Os fundos são blocos anônimos
  consecutivos; cada bloco começa com `rounded =` e vale na ordem (1 painel,
  2 tarefa, 3 ativa, 4 urgente, 5 tooltip). Usar `background_id` faz o tint2
  ignorar silenciosamente tudo.
- **tint2 não tem `panel_shadow*` nem `clock_font`.** Opções inexistentes são
  descartadas com aviso; o painel sai sem sombra. A sombra vem do picom.
- **picom: `_GTK_FRAME_EXTENTS@:c`** está depreciado (o `:c` é ignorado). Use
  `_GTK_FRAME_EXTENTS@`.
- **picom precisa *poder* borrar o painel.** Se `class_g = 'tint2'` estiver em
  `blur-background-exclude`, o painel fica translúcido sem blur — parece sujo.
  Só o `window_type = 'desktop'` (o wallpaper) deve ser excluído.
- **`disable_transparency = 1`** no tint2 desliga o canal alfa; mantenha `0`.
- **texto escuro sobre vidro não funciona.** O fundo borrado pode clarear; a
  paleta usa texto claro por isso.

---

## 5. Fora de escopo nesta fase

- `kolinos-desktop` como parte do build padrão (hoje é opt-in).
- Tema de ícones próprio completo (hoje: emblema + `hicolor`/Adwaita).
- Sessão Wayland.
- XFCE/tema de cursor próprios.
