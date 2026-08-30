# agentbox

**Sua VM pessoal de agentes de código, em um container.** Ubuntu + Herdr +
Claude Code, Codex e opencode + Neovim configurado para caber na tela do
celular. Você sobe com um `docker compose up`, conecta por SSH de onde estiver,
e os agentes continuam trabalhando depois que você desconecta.

[![build image](https://github.com/pedrogiroldo/agentbox/actions/workflows/docker-image.yml/badge.svg)](https://github.com/pedrogiroldo/agentbox/actions/workflows/docker-image.yml)

🇺🇸 [English version](README.en.md)

---

## Por que isso existe

Eu queria deixar agentes de código rodando o tempo todo e conseguir acompanhar
de qualquer lugar — inclusive do celular, esperando em uma fila. Três coisas
estavam no caminho:

1. **Fechar o notebook mata o agente.** Uma sessão SSH normal morre junto com a
   conexão, e o agente vai junto.
2. **Nem todo mundo tem uma VM dedicada.** Mas muita gente já paga um VPS
   rodando Coolify ou Dokploy. Se o ambiente for um container, ele sobe ali do
   lado dos outros serviços, sem provisionar máquina nova.
3. **Terminal em celular é hostil.** Editor com barra de status, número
   relativo, sinal de coluna, animação de scroll — em 45 colunas isso não é
   ferramenta, é obstáculo.

O agentbox é a resposta que eu montei para os três. Ele não é um "devcontainer"
de projeto: é uma **máquina de desenvolvimento** que se comporta como uma VM
normal — você dá `sudo apt install`, clona repositórios, instala o que quiser —
só que descartável, versionada em um Dockerfile, e com todos os seus dados em
um volume que fica no seu servidor.

## Como funciona

```
       seu celular / notebook
                │  ssh -p 2222 dev@servidor
                ▼
   ┌────────────────────────────────────────────┐
   │  container agentbox (Ubuntu 24.04)         │
   │                                            │
   │   sshd ──► herdr  (multiplexador)          │
   │              ├─ pane: claude               │
   │              ├─ pane: codex                │
   │              ├─ pane: opencode             │
   │              └─ pane: nvim / shell         │
   │                                            │
   │   /home/dev  ───────────────────────────┐  │
   └─────────────────────────────────────────┼──┘
                                             ▼
                            volume persistente no servidor
                  (repos, credenciais dos agentes, config, histórico)
```

O **Herdr** é a peça central: um multiplexador de terminal feito para agentes
de código. Ele mantém tudo rodando quando você desconecta, e mostra na sidebar
qual agente está trabalhando e qual está esperando resposta sua. É o que
transforma "abrir o terminal no celular" em algo que faz sentido.

## O que vem instalado

| | |
| --- | --- |
| **Base** | Ubuntu 24.04, SSH (só por chave), sudo sem senha, mosh, locales `en_US` e `pt_BR` |
| **Agentes** | Claude Code, Codex CLI, opencode — com as integrações do Herdr já configuradas |
| **Multiplexador** | [Herdr](https://herdr.dev) (e tmux, se você preferir) |
| **Editor** | Neovim + LazyVim, com **modo mobile** automático |
| **Runtimes** | Node.js, Bun, uv, Python 3 |
| **Ferramentas** | git, git-lfs, gh (GitHub CLI), ripgrep, fd, fzf, jq, build-essential, Docker CLI |

## Começando

Pré-requisitos: Docker e Docker Compose na máquina que vai hospedar (seu
servidor, seu VPS, ou seu próprio computador).

```sh
git clone https://github.com/pedrogiroldo/agentbox.git
cd agentbox

make init        # cria o .env já com a chave pública desta máquina
$EDITOR .env     # adicione a chave do celular, ajuste porta, fuso e identidade git

make up          # constrói a imagem e sobe o container
```

O primeiro build demora (ele compila os plugins do Neovim para o primeiro
`nvim` no celular abrir instantâneo). Depois:

```sh
ssh -p 2222 dev@seu-servidor
herdr
```

E é isso. `Ctrl+b` `?` mostra os atalhos, `Ctrl+b` `q` desconecta deixando tudo
rodando.

### Os comandos que você vai usar

```sh
make key       # mostra sua chave pública (cria uma se não existir)
make up        # sobe
make ssh       # conecta a partir desta máquina
make logs      # acompanha o boot e o provisionamento
make shell     # entra no container sem SSH (quando você se trancou do lado de fora)
make update    # reconstrói a imagem e recria o container, preservando o volume
make backup    # empacota o volume em ./backups
```

`make` sozinho lista tudo.

## Do celular

Instale um cliente SSH ([Termius](https://termius.com),
[Blink](https://blink.sh), Termux), **gere a chave no próprio celular** e
adicione a chave pública ao `SSH_PUBLIC_KEY` (uma por linha).

Conectou, rode `herdr`. Os dois atalhos que importam em tela pequena são
`Ctrl+b` `z` (deixa um pane em tela cheia) e `Ctrl+b` `b` (esconde a sidebar).

O Neovim entra em **modo mobile** sozinho quando o terminal tem menos de 90
colunas: sem barra de status, sem número relativo, sem coluna de sinais, com
quebra de linha, `jk` para sair do modo de inserção, explorador de arquivos em
tela cheia e todas as animações desligadas — cada célula redesenhada custa caro
em um link móvel. Em tela grande, nada disso muda.

O passo a passo completo, com as configurações do cliente que fazem diferença,
está em [docs/mobile.md](docs/mobile.md).

## Seus dados ficam no seu servidor

A regra é uma linha:

> **`/home/dev` é um volume no seu servidor. Todo o resto é a imagem.**

Repositórios, credenciais dos agentes, configuração do Neovim, plugins,
histórico do shell, sessões do Herdr e até as chaves de host do SSH ficam no
volume `agentbox-home`. Recriar o container não perde nada — nem o
*fingerprint* que o seu celular já confiou.

Coisas fora do home (um `sudo apt install`, por exemplo) somem quando o
container é recriado. Para que sobrevivam, coloque-as em
`~/.agentbox/provision.sh`, que roda em todo boot, ou no `Dockerfile`, se for
algo pesado. Detalhes e estratégia de backup em
[docs/persistence.md](docs/persistence.md).

## Rodando em Coolify ou Dokploy

Foi para isso que ele nasceu. Crie um recurso do tipo **Docker Compose**,
aponte para este repositório (ou cole
[`deploy/docker-compose.ghcr.yml`](deploy/docker-compose.ghcr.yml) para usar a
imagem pronta, mais rápido em VPS pequeno), defina `SSH_PUBLIC_KEY` e publique
a porta `2222:22` — SSH é TCP puro, o proxy HTTP da plataforma não entra na
história.

Passo a passo em [docs/deploy.md](docs/deploy.md).

## Segurança

O container se recusa a subir sem nenhuma chave configurada, aceita só
autenticação por chave e não permite login de root. Ainda assim, você está
colocando um servidor SSH na internet: a porta padrão é `2222`, restrinja a
origem no firewall, e se puder, não exponha nada — coloque o host numa rede
Tailscale/WireGuard e publique a porta só no IP privado.

Duas coisas merecem leitura antes: montar o socket do Docker dá acesso
equivalente a root **no host**, e as credenciais dos agentes ficam em texto
claro no volume. [docs/security.md](docs/security.md) explica o resto.

## Personalizando

- **Configuração do Neovim**: `image/skel/.config/nvim`. O que está no seu home
  vence sempre; a imagem só adiciona arquivos que ainda não existem.
- **Configuração do Herdr**: `image/skel/.config/herdr/config.toml`
  (`herdr --default-config` lista todas as opções).
- **Mais ferramentas na imagem**: edite o `Dockerfile` e rode `make update`.
- **Mais ferramentas sem rebuild**: `~/.agentbox/provision.sh`.
- **Versões fixas**: `NODE_VERSION`, `NVIM_VERSION`, `CLAUDE_CODE_VERSION`,
  `CODEX_VERSION`, `OPENCODE_VERSION` no `.env`.

## Documentação

- [Uso no celular](docs/mobile.md) — cliente SSH, Herdr, Neovim em tela pequena
- [Persistência](docs/persistence.md) — o que sobrevive, provisionamento, backup
- [Deploy](docs/deploy.md) — VPS, Coolify, Dokploy, várias caixas
- [Agentes](docs/agents.md) — login, integrações, rodar vários em paralelo
- [Segurança](docs/security.md) — exposição, socket do Docker, raio de alcance

## Créditos

[Herdr](https://herdr.dev) · [LazyVim](https://lazyvim.github.io) ·
[Claude Code](https://claude.com/claude-code) ·
[Codex](https://developers.openai.com/codex/cli) ·
[opencode](https://opencode.ai)

## Licença

MIT — veja [LICENSE](LICENSE).
