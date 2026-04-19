#!/usr/bin/env bash
# =============================================================================
# WORKFLOW SÍNCRONO DE AGENTES - DEV HÍBRIDO
# Executa: DeepSeek → Qwen → Phi (revisão) → DeepSeek (testes) → loop → Claude
# Uso: ./workflow.sh "descrição da tarefa"
#      ./workflow.sh --continue "melhorar performance"   ← retoma sessão anterior
#      ./workflow.sh --list                              ← lista sessões salvas
# =============================================================================

set -euo pipefail

# --- Cores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Configurações ---
MAX_LOOP=3                      # tentativas máximas no loop revisão→testes
LOG_DIR="$HOME/.dev-workflow/logs"
SESSIONS_DIR="$HOME/.dev-workflow/sessions"
SESSION_LOG="$LOG_DIR/session_$(date +%Y%m%d_%H%M%S).log"
TASK_FILE="/tmp/dev_task.md"
RESULT_FILE="/tmp/dev_result.md"
MODE="new"                      # "new" | "continue"
CONTINUE_TASK=""

# --- Modelos ---
MODEL_FAST="deepseek-coder:6.7b"
MODEL_DEV="qwen2.5-coder:7b"
MODEL_REVIEW="phi4-mini"

mkdir -p "$LOG_DIR" "$SESSIONS_DIR"

# =============================================================================
# FUNÇÕES UTILITÁRIAS
# =============================================================================

log() {
    echo -e "$1" | tee -a "$SESSION_LOG"
}

separator() {
    log "\n${DIM}────────────────────────────────────────────────────────────${NC}"
}

banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ██████╗ ███████╗██╗   ██╗    ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗"
    echo "  ██╔══██╗██╔════╝██║   ██║    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝"
    echo "  ██║  ██║█████╗  ██║   ██║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ "
    echo "  ██║  ██║██╔══╝  ╚██╗ ██╔╝    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ "
    echo "  ██████╔╝███████╗ ╚████╔╝     ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗"
    echo "  ╚═════╝ ╚══════╝  ╚═══╝       ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "${DIM}  Workflow Síncrono · 1 modelo por vez · zero vazamento de RAM${NC}"
    separator
}

step() {
    local num="$1"
    local title="$2"
    local model="$3"
    log "\n${BOLD}${BLUE}[ FASE $num ]${NC} ${BOLD}$title${NC}"
    log "${DIM}  modelo: $model${NC}"
    separator
}

success() { log "${GREEN}  ✔ $1${NC}"; }
warn()    { log "${YELLOW}  ⚠ $1${NC}"; }
info()    { log "${CYAN}  ► $1${NC}"; }
error()   { log "${RED}  ✖ $1${NC}"; }

# =============================================================================
# CONTROLE DO OLLAMA
# =============================================================================

ollama_start() {
    info "Iniciando Ollama..."
    if ! pgrep -x "ollama" > /dev/null 2>&1; then
        sudo systemctl start ollama 2>/dev/null || ollama serve &>/dev/null &
        sleep 2
    fi
    success "Ollama ativo"
}

ollama_stop() {
    info "Encerrando Ollama (modo nuclear)..."

    # 1. Para qualquer modelo rodando via CLI
    pkill -f "ollama run"    2>/dev/null || true

    # 2. Para o servidor Ollama por todas as vias possíveis
    sudo systemctl stop ollama 2>/dev/null || true   # systemd
    pkill -f "ollama serve"  2>/dev/null || true     # processo direto
    pkill -x "ollama"        2>/dev/null || true     # binário raiz

    # 3. Aguarda processos morrerem de verdade
    local tentativas=0
    while pgrep -x "ollama" > /dev/null 2>&1 && [ $tentativas -lt 10 ]; do
        sleep 0.5
        tentativas=$((tentativas + 1))
    done

    # 4. Se ainda sobrou algo, mata com força
    if pgrep -x "ollama" > /dev/null 2>&1; then
        warn "Ollama resistindo — forçando SIGKILL..."
        sudo pkill -9 -x "ollama" 2>/dev/null || pkill -9 -x "ollama" 2>/dev/null || true
        sleep 1
    fi

    # 5. Limpa socket e arquivos de lock do Ollama
    rm -f /tmp/ollama*.sock /tmp/ollama*.pid 2>/dev/null || true

    # 6. Confirma
    if pgrep -x "ollama" > /dev/null 2>&1; then
        warn "Processo Ollama ainda detectado (pode ser zumbi inofensivo)"
    else
        success "Ollama encerrado — nenhum processo restante"
    fi
}

ollama_run() {
    local model="$1"
    local prompt="$2"
    local output_file="$3"
    local tmp_out="/tmp/ollama_stream_$$.tmp"

    ollama_start

    # Spinner em tempo real enquanto o modelo processa
    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_i=0
    local start_time=$SECONDS

    # Roda o modelo em background, captura output
    ollama run "$model" "$prompt" > "$tmp_out" 2>/dev/null &
    local pid=$!

    # Mostra spinner + tokens gerados até agora enquanto aguarda
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start_time ))
        local tokens=0
        [ -f "$tmp_out" ] && tokens=$(wc -w < "$tmp_out" 2>/dev/null || echo 0)
        printf "\r  ${CYAN}%s${NC} ${DIM}%s${NC}  ${DIM}~%d tokens · %ds${NC}   " \
            "${spinner[$spin_i]}" "$model" "$tokens" "$elapsed"
        spin_i=$(( (spin_i + 1) % ${#spinner[@]} ))
        sleep 0.1
    done

    # Limpa a linha do spinner
    printf "\r%-70s\r" " "

    # Filtra escape codes ANSI/terminal antes de salvar
    sed 's/\[[0-9;]*[a-zA-Z]//g; s///g; s/\[[0-9]*[A-Za-z]//g'         "$tmp_out" > "$output_file"
    rm -f "$tmp_out"

    local elapsed=$(( SECONDS - start_time ))
    local tokens
    tokens=$(wc -w < "$output_file" 2>/dev/null || echo 0)
    success "Concluído em ${elapsed}s · ~${tokens} tokens"

    # Exibe o resultado
    cat "$output_file"

    ollama_stop
}

# =============================================================================
# LIMPEZA TOTAL (chamada no final ou em caso de erro)
# =============================================================================

cleanup() {
    separator
    log "\n${BOLD}${MAGENTA}[ LIMPEZA ]${NC} Encerrando tudo sem deixar vestígios..."

    # Para Ollama por todas as vias
    pkill -f "ollama run"    2>/dev/null || true
    pkill -f "ollama serve"  2>/dev/null || true
    pkill -x "ollama"        2>/dev/null || true
    sudo systemctl stop ollama 2>/dev/null || true

    # Espera e força se necessário
    sleep 1
    if pgrep -x "ollama" > /dev/null 2>&1; then
        sudo pkill -9 -x "ollama" 2>/dev/null || pkill -9 -x "ollama" 2>/dev/null || true
        sleep 1
    fi

    # Remove sockets e locks do Ollama
    rm -f /tmp/ollama*.sock /tmp/ollama*.pid 2>/dev/null || true

    # Salva o resultado final como sessão antes de apagar os /tmp
    if [ -f /tmp/dev_result.md ] && [ -s /tmp/dev_result.md ]; then
        local session_id
        session_id="$(date +%Y%m%d_%H%M%S)"
        local session_file="$SESSIONS_DIR/session_${session_id}.md"
        {
            echo "# Sessão: $session_id"
            echo "## Tarefa"
            cat "$TASK_FILE" 2>/dev/null || echo "(sem tarefa)"
            echo ""
            echo "## Código final"
            cat /tmp/dev_result.md
            echo ""
            echo "## Testes"
            cat /tmp/dev_tests.md 2>/dev/null || echo "(sem testes)"
            echo ""
            echo "## Revisão"
            cat /tmp/dev_review.md 2>/dev/null || echo "(sem revisão)"
        } > "$session_file"
        success "Sessão salva: $session_file"
    fi

    # Remove arquivos temporários da sessão
    rm -f /tmp/dev_task.md \
          /tmp/dev_result.md \
          /tmp/dev_tests.md \
          /tmp/dev_review.md \
          /tmp/dev_context.md \
          /tmp/test_status \
          /tmp/test_run.py \
          /tmp/test_run.test.js \
          /tmp/ollama_output.tmp

    # Libera cache de página do Linux
    sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

    # Relatório final de processos
    if pgrep -x "ollama" > /dev/null 2>&1; then
        warn "Atenção: processo Ollama ainda visível (pode ser zumbi no kernel)"
    else
        success "RAM liberada · processos encerrados · arquivos temporários removidos"
    fi

    log "\n${DIM}  Log salvo em: $SESSION_LOG${NC}"
    log "${DIM}  Sessões em:   $SESSIONS_DIR${NC}"
    separator
}

# Garante limpeza mesmo se o script for interrompido (Ctrl+C, erro, etc.)
trap cleanup EXIT

# =============================================================================
# GERENCIAMENTO DE SESSÕES (--continue / --list)
# =============================================================================

listar_sessoes() {
    echo -e "\n${BOLD}Sessões salvas:${NC}\n"
    local i=0
    local sessions=()
    while IFS= read -r -d '' f; do
        sessions+=("$f")
    done < <(find "$SESSIONS_DIR" -name "session_*.md" -print0 2>/dev/null | sort -rz)

    if [ ${#sessions[@]} -eq 0 ]; then
        warn "Nenhuma sessão encontrada em $SESSIONS_DIR"
        return
    fi

    for f in "${sessions[@]}"; do
        i=$((i + 1))
        local name
        name=$(basename "$f" .md)
        local tarefa
        tarefa=$(grep -A1 "^## Tarefa" "$f" 2>/dev/null | tail -1 || echo "(sem descrição)")
        printf "  ${CYAN}%2d.${NC} ${BOLD}%s${NC}\n      %s\n\n" "$i" "$name" "$tarefa"
        [ $i -ge 10 ] && break
    done
    echo -e "${DIM}  Total: ${#sessions[@]} sessões · use 'devflow --continue \"nova tarefa\"'${NC}\n"
}

carregar_ultima_sessao() {
    local ultima
    ultima=$(find "$SESSIONS_DIR" -name "session_*.md" 2>/dev/null | sort | tail -1)

    if [ -z "$ultima" ]; then
        warn "Nenhuma sessão anterior encontrada. Iniciando do zero..."
        return 1
    fi

    info "Carregando sessão: $(basename "$ultima")"

    # Extrai o código da sessão anterior e restaura em /tmp
    awk '/^## Código final/{found=1; next} /^## Testes/{found=0} found' "$ultima" > /tmp/dev_result.md
    awk '/^## Testes/{found=1; next} /^## Revisão/{found=0} found' "$ultima" > /tmp/dev_tests.md

    local tarefa_anterior
    tarefa_anterior=$(awk '/^## Tarefa/{found=1; next} /^## Código/{found=0} found' "$ultima")

    success "Contexto anterior restaurado"
    log "${DIM}  Tarefa anterior: $tarefa_anterior${NC}"
    log "${DIM}  Arquivo: $ultima${NC}"
    return 0
}

# =============================================================================
# FASES DO WORKFLOW
# =============================================================================

fase_1_geracao() {
    local task="$1"
    step "1" "DeepSeek Coder — Geração rápida" "$MODEL_FAST"

    local prompt="Você é um dev experiente. Implemente o seguinte de forma limpa e funcional.
NÃO explique, apenas retorne o código com comentários breves.
TAREFA: $task"

    ollama_run "$MODEL_FAST" "$prompt" "/tmp/dev_result.md"
    success "Código gerado"
}

fase_2_refinamento() {
    step "2" "Qwen2.5 Coder — Refinamento e arquitetura" "$MODEL_DEV"

    local codigo
    codigo=$(cat /tmp/dev_result.md)

    local prompt="Você é um dev sênior fazendo code review e refatoração.
Analise o código abaixo e:
1. Melhore a estrutura e legibilidade
2. Corrija problemas óbvios de arquitetura
3. Aplique boas práticas
4. Retorne APENAS o código melhorado, sem explicações longas.

CÓDIGO:
$codigo"

    ollama_run "$MODEL_DEV" "$prompt" "/tmp/dev_result.md"
    success "Código refinado"
}

fase_3_revisao() {
    step "3" "Phi-4-mini — Revisão e detecção de bugs" "$MODEL_REVIEW"

    local codigo
    codigo=$(cat /tmp/dev_result.md)

    local prompt="Você é um QA técnico. Analise o código abaixo e liste:
1. Bugs encontrados (se houver)
2. Inconsistências lógicas
3. Problemas de segurança óbvios
4. Seja direto e objetivo — máximo 10 linhas de resposta.
Se não encontrar problemas, responda: 'OK: código aprovado para testes.'

CÓDIGO:
$codigo"

    ollama_run "$MODEL_REVIEW" "$prompt" "/tmp/dev_review.md"
    cat /tmp/dev_review.md
}

fase_4_testes() {
    local tentativa="$1"
    step "4" "DeepSeek Coder — Geração e execução de testes (tentativa $tentativa/$MAX_LOOP)" "$MODEL_FAST"

    local codigo
    codigo=$(cat /tmp/dev_result.md)

    local prompt="Você é um dev especializado em testes. Para o código abaixo:
1. Escreva testes unitários completos (use a framework adequada para a linguagem)
2. Inclua casos de borda
3. Retorne APENAS o código de testes, pronto para executar.

CÓDIGO A TESTAR:
$codigo"

    ollama_run "$MODEL_FAST" "$prompt" "/tmp/dev_tests.md"
    success "Testes gerados"

    # Tenta executar os testes automaticamente se possível
    executar_testes
}

executar_testes() {
    info "Tentando executar testes automaticamente..."

    local tests
    tests=$(cat /tmp/dev_tests.md)

    # Detecta linguagem e executa
    if echo "$tests" | grep -q "import pytest\|def test_"; then
        info "Detectado: Python/pytest"
        echo "$tests" > /tmp/test_run.py
        if python3 -m pytest /tmp/test_run.py -v 2>&1 | tee -a "$SESSION_LOG"; then
            success "Testes Python passaram!"
            echo "PASSED" > /tmp/test_status
        else
            warn "Testes Python falharam"
            echo "FAILED" > /tmp/test_status
        fi
        rm -f /tmp/test_run.py

    elif echo "$tests" | grep -q "describe\|it(\|test("; then
        info "Detectado: JavaScript/Jest"
        echo "$tests" > /tmp/test_run.test.js
        if command -v npx &>/dev/null; then
            if npx jest /tmp/test_run.test.js 2>&1 | tee -a "$SESSION_LOG"; then
                success "Testes JS passaram!"
                echo "PASSED" > /tmp/test_status
            else
                warn "Testes JS falharam"
                echo "FAILED" > /tmp/test_status
            fi
        fi
        rm -f /tmp/test_run.test.js

    else
        warn "Linguagem não detectada automaticamente para execução."
        info "Testes gerados em: /tmp/dev_tests.md"
        echo "MANUAL" > /tmp/test_status
    fi
}

# =============================================================================
# LOOP DE REVISÃO + TESTES
# =============================================================================

loop_revisao_testes() {
    local tentativa=0
    local aprovado=false

    while [ $tentativa -lt $MAX_LOOP ]; do
        tentativa=$((tentativa + 1))

        # Revisão com Phi
        fase_3_revisao

        # Verifica se o revisor aprovou
        if grep -qi "OK: código aprovado" /tmp/dev_review.md; then
            success "Revisão aprovada pelo Phi-4-mini"
        else
            warn "Revisor encontrou problemas. Corrigindo com Qwen..."
            fase_2_refinamento
        fi

        # Gera e executa testes
        fase_4_testes "$tentativa"

        local status
        status=$(cat /tmp/test_status 2>/dev/null || echo "MANUAL")

        if [ "$status" = "PASSED" ]; then
            success "Testes passaram na tentativa $tentativa!"
            aprovado=true
            break
        elif [ "$status" = "MANUAL" ]; then
            # Pede confirmação manual
            separator
            echo -e "\n${YELLOW}${BOLD}  Os testes foram gerados mas precisam de execução manual.${NC}"
            echo -e "  Arquivo: ${BOLD}/tmp/dev_tests.md${NC}\n"
            read -rp "  Os testes passaram? (s/n): " resposta
            if [[ "$resposta" =~ ^[Ss]$ ]]; then
                aprovado=true
                break
            fi
        else
            warn "Testes falharam na tentativa $tentativa de $MAX_LOOP"
            if [ $tentativa -lt $MAX_LOOP ]; then
                info "Voltando para revisão..."
            fi
        fi
    done

    if [ "$aprovado" = false ]; then
        warn "Loop atingiu $MAX_LOOP tentativas sem aprovação."
        warn "Escalando para Claude com contexto completo..."
        gerar_contexto_claude "loop_excedido"
    fi

    echo "$aprovado"
}

# =============================================================================
# PREPARAÇÃO PARA O CLAUDE
# =============================================================================

gerar_contexto_claude() {
    local motivo="${1:-normal}"
    separator
    log "\n${BOLD}${MAGENTA}[ FASE 5 ]${NC} ${BOLD}Preparando contexto para o Claude (sênior externo)${NC}"

    local codigo
    codigo=$(cat /tmp/dev_result.md 2>/dev/null || echo "")
    local testes
    testes=$(cat /tmp/dev_tests.md 2>/dev/null || echo "")
    local revisao
    revisao=$(cat /tmp/dev_review.md 2>/dev/null || echo "")
    local task
    task=$(cat "$TASK_FILE" 2>/dev/null || echo "")

    cat > "$RESULT_FILE" << EOF
# Contexto para revisão — Claude (Sênior)

## Tarefa original
$task

## Motivo do escalonamento
$motivo

## Código final (pós-refinamento local)
\`\`\`
$codigo
\`\`\`

## Testes gerados
\`\`\`
$testes
\`\`\`

## Última revisão do Phi-4-mini
$revisao

---
*Gerado automaticamente pelo workflow síncrono em $(date)*
EOF

    success "Contexto salvo em: $RESULT_FILE"

    # Abre o arquivo no VSCode automaticamente
    if command -v code &>/dev/null; then
        info "Abrindo no VSCode..."
        code "$RESULT_FILE"
        success "Arquivo aberto no VSCode — copie e cole no Claude"
    else
        info "Abra o arquivo manualmente: $RESULT_FILE"
    fi

    separator
    echo -e "${BOLD}${GREEN}"
    echo "  ┌─────────────────────────────────────────────────┐"
    echo "  │  Cole o conteúdo de $RESULT_FILE no Claude  │"
    echo "  │  Pergunta sugerida:                             │"
    echo "  │  'Revise a arquitetura e valide as decisões.'   │"
    echo "  └─────────────────────────────────────────────────┘"
    echo -e "${NC}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    banner

    # ── Parse de argumentos ──
    if [ $# -eq 0 ]; then
        echo -e "${RED}Uso:${NC}"
        echo -e "  $0 \"descrição da tarefa\""
        echo -e "  $0 --continue \"melhorar performance\"   ${DIM}← retoma código da última sessão${NC}"
        echo -e "  $0 --list                               ${DIM}← lista sessões salvas${NC}"
        exit 1
    fi

    case "$1" in
        --list|-l)
            listar_sessoes
            exit 0
            ;;
        --continue|-c)
            MODE="continue"
            shift
            CONTINUE_TASK="${*:-melhorar o código anterior}"
            ;;
        *)
            MODE="new"
            ;;
    esac

    local task
    if [ "$MODE" = "continue" ]; then
        task="$CONTINUE_TASK"
    else
        task="$*"
    fi

    echo "$task" > "$TASK_FILE"

    log "${BOLD}Modo:${NC}  $MODE"
    log "${BOLD}Tarefa:${NC} $task"
    log "${DIM}Início: $(date)${NC}"
    log "${DIM}Log:    $SESSION_LOG${NC}"
    separator

    # ── Modo continue: carrega contexto anterior ──
    if [ "$MODE" = "continue" ]; then
        if carregar_ultima_sessao; then
            log ""
            warn "Modo --continue: pulando Fase 1 (geração) e Fase 2 (refinamento inicial)"
            info "Retomando a partir da revisão com o novo objetivo: ${BOLD}$task${NC}"

            # Injeta o novo objetivo no código existente via Qwen antes de revisar
            separator
            step "2*" "Qwen2.5 Coder — Aplicando novo objetivo ao código existente" "$MODEL_DEV"
            local codigo_anterior
            codigo_anterior=$(cat /tmp/dev_result.md)
            local prompt_continue="Você é um dev sênior. Você tem o código abaixo de uma sessão anterior.
Aplique a seguinte melhoria/modificação SEM quebrar o que já funciona:
OBJETIVO: $task

CÓDIGO ATUAL:
$codigo_anterior

Retorne APENAS o código modificado, sem explicações."
            ollama_run "$MODEL_DEV" "$prompt_continue" "/tmp/dev_result.md"
            success "Código atualizado com o novo objetivo"
        else
            warn "Sessão anterior não encontrada — iniciando do zero"
            MODE="new"
        fi
    fi

    # ── Fluxo normal (ou fallback do continue) ──
    if [ "$MODE" = "new" ]; then
        # Checagem de modelos
        info "Verificando modelos disponíveis..."
        ollama_start
        for model in "$MODEL_FAST" "$MODEL_DEV" "$MODEL_REVIEW"; do
            if ollama list 2>/dev/null | grep -q "${model%%:*}"; then
                success "  $model"
            else
                warn "  $model — não encontrado (será baixado automaticamente)"
            fi
        done
        ollama_stop

        separator
        echo -e "${DIM}  Pressione Enter para iniciar o workflow ou Ctrl+C para cancelar${NC}"
        read -r

        fase_1_geracao "$task"
        fase_2_refinamento
    fi

    # ── Loop: Revisão → Testes ──
    resultado=$(loop_revisao_testes)

    # ── Fase 5: Claude ──
    if [ "$resultado" = "true" ]; then
        gerar_contexto_claude "testes_aprovados"
    fi

    separator
    log "\n${BOLD}${GREEN}  Workflow concluído!${NC}"
    log "${DIM}  Duração: $((SECONDS / 60))m $((SECONDS % 60))s${NC}"
    log "${DIM}  Sessão salva automaticamente em: $SESSIONS_DIR${NC}"
    # cleanup é chamado automaticamente pelo trap EXIT
}

main "$@"
