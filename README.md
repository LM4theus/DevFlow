# Dev Workflow — Orquestrador de Agentes de IA

Um sistema de desenvolvimento híbrido que combina modelos de IA locais (gratuitos) com IA avançada online, organizados em hierarquia de responsabilidades. Execução síncrona — 1 modelo por vez, sem desperdício de RAM.

---

## Hierarquia de agentes

```
Product Owner (você)
        │
        ▼
IA Sênior — Claude / outra IA avançada  (via browser, sem consumo de API)
        │
        │  gera prompts otimizados para os agentes locais
        │  revisa o resultado final
        ▼
Equipe local — DeepSeek · Qwen · Phi-4-mini  (via Ollama, gratuito, offline)
        │
        │  geração → refinamento → revisão → testes
        ▼
Resultado
        │
        ▼
IA Sênior — valida arquitetura e decisões críticas
        │
        ▼
Product Owner — aprovação final
```

**O fluxo na prática:**

1. Você descreve o objetivo em linguagem natural para a IA Sênior
2. A IA Sênior gera um prompt técnico detalhado
3. Você cola o prompt no `devflow` — os agentes locais trabalham em sequência
4. O resultado é apresentado à IA Sênior para revisão arquitetural
5. Aprovado, você recebe o entregável final

Isso permite usar o melhor de cada camada: **você decide, a sênior arquiteta, as locais executam** — sem gastar tokens de API em tarefas repetitivas.

---

## Estrutura do fluxo técnico

```
devflow "prompt"
        │
        ▼
[ Fase 1 ] DeepSeek Coder 6.7B — geração rápida
        │
        ▼
[ Fase 2 ] Qwen2.5 Coder 7B — refinamento e arquitetura
        │
        ▼
[ Loop — máx. 3x ] ◄──────────────────────────┐
        │                                       │
        ▼                                       │
[ Fase 3 ] Phi-4-mini — revisão e bugs          │
        │                                       │
        ▼                                       │
[ Fase 4 ] DeepSeek — gera e executa testes     │
        │                                       │
        ├── testes falharam ────────────────────┘
        │
        ▼ testes aprovados
[ Fase 5 ] Contexto gerado para IA Sênior
        │
        ▼
Limpeza total — RAM liberada, zero vestígios
```

---

## Requisitos

- Linux (Debian/Ubuntu ou derivados)
- [Ollama](https://ollama.com) instalado
- Modelos baixados:
  ```bash
  ollama pull deepseek-coder:6.7b
  ollama pull qwen2.5-coder:7b
  ollama pull phi4-mini
  ```
- Bash 4+
- VSCode (opcional, para integração com tasks)

---

## Instalação

```bash
# 1. Clone o repositório
git clone https://github.com/seu-usuario/dev-workflow.git
cd dev-workflow

# 2. Rode o instalador
chmod +x install.sh
./install.sh

# 3. Recarrega o shell
source ~/.bashrc   # bash
source ~/.zshrc    # zsh
```

> **Usuários zsh:** o instalador detecta o shell automaticamente. Se os aliases não carregarem, rode:
> ```bash
> grep -A 60 "DEV WORKFLOW SÍNCRONO" ~/.bashrc >> ~/.zshrc && source ~/.zshrc
> ```

---

## Uso

### Fluxo completo

```bash
# Nova tarefa
devflow "Crie uma API REST em Python com Flask e autenticação JWT"

# Retomar sessão anterior com novo objetivo
devcon "adicionar validação de campos obrigatórios"
devcon "melhorar tratamento de erros"

# Listar sessões salvas
devlist
```

### Comandos avulsos

```bash
iaon        # liga o Ollama
iaoff       # desliga tudo (nuclear: SIGTERM → SIGKILL → drop_caches)
fast        # abre DeepSeek diretamente no terminal
dev         # abre Qwen diretamente no terminal
review      # abre Phi-4-mini diretamente no terminal
devflow     # inicia workflow completo (nova tarefa)
devcon      # retoma última sessão com novo objetivo
devlist     # lista sessões salvas
devstatus   # verifica se Ollama está rodando + RAM consumida em MB
devclean    # remove arquivos temporários manualmente
devlogs     # lista os últimos logs de sessão
```

### Via VSCode

```bash
# Copia a config para o projeto atual
cp -r ~/.vscode-workflow/.vscode/ ./

# Ou globalmente (funciona em qualquer projeto)
cp -r ~/.vscode-workflow/.vscode/ ~/.vscode/
```

Depois: `Ctrl+Shift+B` → digita a tarefa → workflow roda no terminal integrado.

---

## Papéis de cada modelo

| Modelo | Papel | Uso típico |
|---|---|---|
| DeepSeek Coder 6.7B | Executor rápido | Geração, boilerplate, testes |
| Qwen2.5 Coder 7B | Dev pleno | Refatoração, lógica complexa, integração |
| Phi-4-mini | Revisor / QA | Bugs, inconsistências, validação lógica |
| IA Sênior (Claude etc.) | Arquiteto sênior | Prompts otimizados, revisão final, decisões críticas |

---

## Uso consciente da IA Sênior

| Onde usar | Para quê |
|---|---|
| Browser (Claude.ai / similar) | Gerar prompts para `devflow`, revisar resultados, planejamento |
| Claude Code no VSCode | Decisões de arquitetura, refatorações críticas com arquivo aberto |
| `devflow` local | Todo o trabalho de geração e execução de código |

> Quanto mais caro o recurso, mais raro e estratégico o uso.
> `devflow` cobre ~90% do trabalho — reserve a IA Sênior para o que realmente importa.

---

## Arquivos gerados

| Arquivo | Conteúdo | Persiste? |
|---|---|---|
| `/tmp/dev_result.md` | Código atual | ✗ removido ao final |
| `/tmp/dev_tests.md` | Testes gerados | ✗ removido ao final |
| `/tmp/dev_review.md` | Análise do Phi | ✗ removido ao final |
| `/tmp/test_status` | `PASSED` / `FAILED` / `MANUAL` | ✗ removido ao final |
| `~/.dev-workflow/sessions/session_*.md` | Sessão completa | ✔ para uso com `--continue` |
| `~/.dev-workflow/logs/session_*.log` | Log completo | ✔ para auditoria |

---

## Loop de revisão + testes

O workflow tenta até **3 vezes** (configurável em `MAX_LOOP`):

1. Phi-4-mini revisa o código
2. Se encontrar problemas → Qwen corrige → volta ao passo 1
3. DeepSeek gera e executa os testes automaticamente (Python/pytest e JS/Jest detectados automaticamente)
4. Testes passaram → contexto gerado para a IA Sênior
5. Testes falharam → volta ao passo 1
6. Após 3 tentativas → escala direto para a IA Sênior com contexto completo

---

## Como o `iaoff` funciona (modo nuclear)

Sequência de 6 etapas garantindo zero resquício na RAM:

1. `pkill -f "ollama run"` — mata o modelo respondendo
2. `pkill -f "ollama serve"` — mata o servidor HTTP
3. `pkill -x "ollama"` — mata o binário raiz
4. `systemctl stop ollama` — encerra via systemd
5. Aguarda 5s; se ainda vivo → `SIGKILL -9`
6. Remove sockets/locks + `sync; echo 3 > /proc/sys/vm/drop_caches`

---

## Configuração

No topo do `workflow.sh`:

```bash
MAX_LOOP=3                        # tentativas máximas no loop
MODEL_FAST="deepseek-coder:6.7b"  # executor rápido
MODEL_DEV="qwen2.5-coder:7b"      # dev pleno
MODEL_REVIEW="phi4-mini"          # revisor
```

---

## Regras de ouro

- Nunca 2 modelos ao mesmo tempo
- Fechar browser antes de rodar modelos locais
- VM offline durante sessão de dev com IA
- `iaoff` sempre ao terminar — sem exceção
- Prompts detalhados = resultados melhores (use a IA Sênior para gerá-los)

---

## Limpeza manual (emergência)

```bash
pkill -f "ollama run"
pkill -f "ollama serve"
sudo pkill -9 -x "ollama"
sudo systemctl stop ollama
rm -f /tmp/dev_*.md /tmp/test_status
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
pgrep -a ollama || echo "limpo"
```

---

## Estrutura do repositório

```
dev-workflow/
├── workflow.sh          # motor principal do fluxo
├── install.sh           # instalador — aliases, VSCode, verificações
└── README.md            # este arquivo
```

Após instalação, o sistema cria:
```
~/.dev-workflow/
├── logs/                # logs de cada sessão
├── sessions/            # sessões salvas (para --continue)
└── workflow.sh          # cópia instalada
```
