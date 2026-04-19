#!/usr/bin/env bash
# =============================================================================
# INSTALAÇÃO DO WORKFLOW SÍNCRONO DE AGENTES
# Configura aliases, instala modelos e integra com VSCode
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

WORKFLOW_DIR="$HOME/.dev-workflow"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()    { echo -e "${CYAN}  ► $1${NC}"; }
success() { echo -e "${GREEN}  ✔ $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $1${NC}"; }

echo -e "\n${BOLD}${CYAN}  Instalando Workflow Síncrono de Agentes${NC}"
echo -e "${DIM}  ────────────────────────────────────────${NC}\n"

# 1. Cria estrutura de diretórios
info "Criando diretórios..."
mkdir -p "$WORKFLOW_DIR/logs"
mkdir -p "$WORKFLOW_DIR/sessions"
cp "$SCRIPT_DIR/workflow.sh" "$WORKFLOW_DIR/workflow.sh"
chmod +x "$WORKFLOW_DIR/workflow.sh"
success "Diretórios criados em $WORKFLOW_DIR"

# 2. Configura aliases no shell
info "Configurando aliases no shell..."

# Detecta o shell em uso
SHELL_RC="$HOME/.bashrc"
if [ -n "${ZSH_VERSION:-}" ] || [ "$SHELL" = "/bin/zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
fi

ALIAS_BLOCK="
# ─── DEV WORKFLOW SÍNCRONO ────────────────────────────────────────────────────
alias iaon='sudo systemctl start ollama && echo \"Ollama ON\"'

# iaoff nuclear: mata tudo, sem exceção, sem resquício
iaoff() {
    echo '⬛ Encerrando Ollama (modo nuclear)...'
    pkill -f 'ollama run'   2>/dev/null || true
    pkill -f 'ollama serve' 2>/dev/null || true
    pkill -x 'ollama'       2>/dev/null || true
    sudo systemctl stop ollama 2>/dev/null || true
    sleep 1
    # força SIGKILL se ainda sobrou algo
    if pgrep -x 'ollama' > /dev/null 2>&1; then
        echo '  forçando SIGKILL...'
        sudo pkill -9 -x 'ollama' 2>/dev/null || pkill -9 -x 'ollama' 2>/dev/null || true
        sleep 1
    fi
    rm -f /tmp/ollama*.sock /tmp/ollama*.pid 2>/dev/null || true
    sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    pgrep -x 'ollama' > /dev/null 2>&1 && echo '⚠ processo ainda visível (zumbi)' || echo '✔ Ollama encerrado — RAM liberada'
}

alias dev='ollama run qwen2.5-coder:7b'
alias fast='ollama run deepseek-coder:6.7b'
alias review='ollama run phi4-mini'
alias devflow='$WORKFLOW_DIR/workflow.sh'
alias devcon='$WORKFLOW_DIR/workflow.sh --continue'
alias devlist='$WORKFLOW_DIR/workflow.sh --list'
alias devlogs='ls -lt $WORKFLOW_DIR/logs/ | head -10'
alias devclean='rm -f /tmp/dev_*.md /tmp/test_*.{py,js} /tmp/test_status && echo \"Temporários removidos\"'
alias devstatus='pgrep -a ollama && echo \"RAM ollama: \$(ps -o rss= -p \$(pgrep -x ollama) 2>/dev/null | awk \"{sum+=\\\$1} END {printf \\\"%.0f MB\\\", sum/1024}\")\" || echo \"Ollama não está rodando\"'
# ──────────────────────────────────────────────────────────────────────────────
"

# Evita duplicar ao rodar install múltiplas vezes
if ! grep -q "DEV WORKFLOW SÍNCRONO" "$SHELL_RC" 2>/dev/null; then
    echo "$ALIAS_BLOCK" >> "$SHELL_RC"
    success "Aliases adicionados em $SHELL_RC"
else
    warn "Aliases já existem em $SHELL_RC — pulando"
fi

# 3. Configura o governor de CPU para performance (opcional)
CPU_GOVERNOR_SCRIPT="$WORKFLOW_DIR/cpu_perf.sh"
cat > "$CPU_GOVERNOR_SCRIPT" << 'EOF'
#!/usr/bin/env bash
# Ativa modo performance durante IA, volta para powersave depois
case "$1" in
    on)
        echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1 || true
        echo "CPU: modo performance"
        ;;
    off)
        echo powersave | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1 || true
        echo "CPU: modo powersave"
        ;;
esac
EOF
chmod +x "$CPU_GOVERNOR_SCRIPT"
success "Script de CPU criado"

# 4. Verifica se Ollama está instalado
info "Verificando Ollama..."
if command -v ollama &>/dev/null; then
    success "Ollama encontrado: $(ollama --version 2>/dev/null || echo 'versão desconhecida')"
else
    warn "Ollama não encontrado. Instale em: https://ollama.com"
    echo -e "  ${DIM}  curl -fsSL https://ollama.com/install.sh | sh${NC}"
fi

# 5. Verifica modelos instalados
info "Verificando modelos..."
if command -v ollama &>/dev/null; then
    for model in "deepseek-coder:6.7b" "qwen2.5-coder:7b" "phi4-mini"; do
        if ollama list 2>/dev/null | grep -q "${model%%:*}"; then
            success "  $model — já instalado"
        else
            warn "  $model — não encontrado"
            echo -e "  ${DIM}  Execute: ollama pull $model${NC}"
        fi
    done
fi

# 6. Configura tarefa no VSCode (tasks.json)
VSCODE_DIR="$HOME/.vscode-workflow"
mkdir -p "$VSCODE_DIR/.vscode"

cat > "$VSCODE_DIR/.vscode/tasks.json" << EOF
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Dev Workflow: iniciar",
            "type": "shell",
            "command": "$WORKFLOW_DIR/workflow.sh",
            "args": ["\${input:taskDescription}"],
            "group": {
                "kind": "build",
                "isDefault": true
            },
            "presentation": {
                "reveal": "always",
                "panel": "new",
                "focus": true,
                "clear": true
            },
            "problemMatcher": []
        },
        {
            "label": "Dev Workflow: status Ollama",
            "type": "shell",
            "command": "pgrep -a ollama || echo 'Ollama não está rodando'",
            "presentation": {
                "reveal": "always",
                "panel": "shared"
            },
            "problemMatcher": []
        },
        {
            "label": "Dev Workflow: limpar temporários",
            "type": "shell",
            "command": "rm -f /tmp/dev_*.md /tmp/test_status && echo 'Limpo.'",
            "presentation": {
                "reveal": "always",
                "panel": "shared"
            },
            "problemMatcher": []
        },
        {
            "label": "Dev Workflow: ver último resultado",
            "type": "shell",
            "command": "cat /tmp/dev_result.md 2>/dev/null || echo 'Nenhum resultado disponível'",
            "presentation": {
                "reveal": "always",
                "panel": "shared"
            },
            "problemMatcher": []
        }
    ],
    "inputs": [
        {
            "id": "taskDescription",
            "description": "Descreva a tarefa para os agentes:",
            "default": "criar função de login com JWT",
            "type": "promptString"
        }
    ]
}
EOF

cat > "$VSCODE_DIR/.vscode/keybindings-suggestion.json" << 'EOF'
[
    {
        "key": "ctrl+shift+w",
        "command": "workbench.action.tasks.runTask",
        "args": "Dev Workflow: iniciar"
    }
]
EOF

success "Configuração VSCode criada em $VSCODE_DIR/.vscode/"

# 7. Resumo final
echo -e "\n${BOLD}${GREEN}  ✔ Instalação concluída!${NC}\n"
echo -e "${DIM}  ────────────────────────────────────────${NC}"
echo -e "${BOLD}  Como usar:${NC}"
echo ""
echo -e "  ${CYAN}Terminal:${NC}"
echo -e "    source $SHELL_RC                    # recarrega aliases"
echo -e "    devflow \"criar API REST em Python\"  # inicia o workflow"
echo ""
echo -e "  ${CYAN}VSCode:${NC}"
echo -e "    1. Copie $VSCODE_DIR/.vscode/ para sua pasta de projeto"
echo -e "    2. Ctrl+Shift+B para iniciar o workflow direto no terminal do VSCode"
echo ""
echo -e "  ${CYAN}Aliases disponíveis:${NC}"
echo -e "    ${DIM}iaon      ${NC}— liga o Ollama"
echo -e "    ${DIM}iaoff     ${NC}— desliga tudo (nuclear: SIGTERM → SIGKILL → drop_caches)"
echo -e "    ${DIM}fast      ${NC}— abre DeepSeek direto"
echo -e "    ${DIM}dev       ${NC}— abre Qwen direto"
echo -e "    ${DIM}review    ${NC}— abre Phi-4-mini direto"
echo -e "    ${DIM}devflow   ${NC}— inicia workflow completo (nova tarefa)"
echo -e "    ${DIM}devcon    ${NC}— retoma última sessão com novo objetivo"
echo -e "    ${DIM}devlist   ${NC}— lista sessões salvas"
echo -e "    ${DIM}devstatus ${NC}— verifica se Ollama está rodando + RAM usada"
echo -e "    ${DIM}devclean  ${NC}— remove arquivos temporários"
echo ""
echo -e "${DIM}  Modelos não instalados? Execute:${NC}"
echo -e "    ollama pull deepseek-coder:6.7b"
echo -e "    ollama pull qwen2.5-coder:7b"
echo -e "    ollama pull phi4-mini"
echo ""
