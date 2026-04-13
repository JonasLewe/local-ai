#!/usr/bin/env bash
# local-ai.sh — Hassle-free local AI stack for macOS (Apple Silicon)
# Stack: Ollama (native) + Open WebUI (Podman) + launchd auto-start
#
# Usage:
#   ./local-ai.sh install     # First-time setup (incl. model download)
#   ./local-ai.sh start       # Start all services (with safety check)
#   ./local-ai.sh stop        # Stop all services, free RAM
#   ./local-ai.sh update      # Pull latest stable Open WebUI image
#   ./local-ai.sh status      # Health check all components
#   ./local-ai.sh doctor      # Diagnose common problems
#   ./local-ai.sh logs        # Tail all relevant logs
#   ./local-ai.sh backup      # Backup chats & settings
#   ./local-ai.sh restore     # Restore from backup
#   ./local-ai.sh uninstall   # Remove everything (keeps Ollama + models)
#
# Requirements: macOS 13+, Apple Silicon, Ollama installed, Homebrew

set -euo pipefail

# ---------- Configuration ----------
readonly SCRIPT_VERSION="2.0.0"
readonly CONFIG_DIR="${HOME}/.config/local-ai"
readonly CONFIG_FILE="$CONFIG_DIR/config"

# Source user config file if it exists (overrides defaults via env vars)
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Ports
readonly OLLAMA_PORT="${OLLAMA_PORT:-11434}"
readonly WEBUI_PORT="${WEBUI_PORT:-3000}"
readonly WEBUI_HOSTNAME="${WEBUI_HOSTNAME:-localhost}"

# Container
readonly WEBUI_IMAGE="ghcr.io/open-webui/open-webui:latest"
readonly WEBUI_CONTAINER="open-webui"
readonly WEBUI_VOLUME="open-webui"

# Model (Ollama naming, e.g. "gemma4-26b" or "llama3.1:8b")
readonly MODEL_ID="${MODEL_ID:-gemma4-26b}"
# Optional: path to existing GGUF file to import instead of pulling from registry
readonly MODEL_GGUF_PATH="${MODEL_GGUF_PATH:-}"
# Estimated model size in GB — used by safety check before loading
readonly MODEL_SIZE_GB="${MODEL_SIZE_GB:-16}"
# Context length (tokens). Ollama default is 4096 — too small for documents.
# 32768 is a safe default on 32GB systems with q8_0 KV cache + flash attention.
readonly MODEL_CONTEXT_LENGTH="${MODEL_CONTEXT_LENGTH:-32768}"

# Ollama runtime tuning (conservative defaults — opt-in for aggressive)
readonly OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-0}"
readonly OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-f16}"

# Podman VM
readonly PODMAN_CPUS="${PODMAN_CPUS:-6}"
readonly PODMAN_MEMORY="${PODMAN_MEMORY:-4096}"

readonly LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
readonly OLLAMA_PLIST="$LAUNCH_AGENTS_DIR/ai.ollama.server.plist"
readonly PODMAN_PLIST="$LAUNCH_AGENTS_DIR/io.podman.machine.plist"
readonly WEBUI_PLIST="$LAUNCH_AGENTS_DIR/ai.openwebui.plist"

readonly LOG_DIR="${HOME}/.local/share/local-ai/logs"
readonly LOG_OLLAMA="$LOG_DIR/ollama.log"
readonly LOG_OLLAMA_ERR="$LOG_DIR/ollama.err.log"
readonly LOG_PODMAN="$LOG_DIR/podman-machine.log"
readonly LOG_WEBUI="$LOG_DIR/openwebui.log"

# Build the user-facing URL
if [[ "$WEBUI_PORT" == "80" ]]; then
  readonly WEBUI_URL="http://$WEBUI_HOSTNAME"
else
  readonly WEBUI_URL="http://$WEBUI_HOSTNAME:$WEBUI_PORT"
fi

# ---------- Output helpers ----------
readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[0;33m'
readonly C_BLUE=$'\033[0;34m'
readonly C_BOLD=$'\033[1m'
readonly C_RESET=$'\033[0m'

info()    { printf "${C_BLUE}ℹ${C_RESET}  %s\n" "$*"; }
success() { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; }
warn()    { printf "${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
error()   { printf "${C_RED}✗${C_RESET}  %s\n" "$*" >&2; }
step()    { printf "\n${C_BOLD}▶ %s${C_RESET}\n" "$*"; }
die()     { error "$*"; exit 1; }

# ---------- Pre-flight checks ----------
require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS"
  [[ "$(uname -m)" == "arm64" ]] || warn "Not Apple Silicon — performance will be poor"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing: $1. Install with: $2"
}

# ---------- Safety checks ----------
# Returns available RAM in GB (free + inactive pages)
get_available_ram_gb() {
  local page_size; page_size=$(vm_stat | head -1 | awk '{print $8}')
  [[ -z "$page_size" ]] && page_size=16384
  local free_pages;     free_pages=$(vm_stat     | awk '/Pages free/      {gsub(/\./, "", $3); print $3}')
  local inactive_pages; inactive_pages=$(vm_stat | awk '/Pages inactive/  {gsub(/\./, "", $3); print $3}')
  echo $(( (free_pages + inactive_pages) * page_size / 1024 / 1024 / 1024 ))
}

# Detect actual model size in GB. Tries (in order):
#   1. ollama list  (works after import/pull)
#   2. GGUF file size on disk  (if MODEL_GGUF_PATH set)
#   3. MODEL_SIZE_GB config value as last-resort fallback
get_model_size_gb() {
  # 1. Ask Ollama directly
  local size_field; size_field=$(ollama list 2>/dev/null | awk -v m="$MODEL_ID" '
    NR==1 { next }                       # skip header
    {
      name = $1
      sub(/:.*/, "", name)               # strip :tag
      if (name == m || $1 == m || $1 == m":latest") {
        print $3, $4                     # size + unit (e.g. "16 GB")
        exit
      }
    }')
  if [[ -n "$size_field" ]]; then
    local n; n=$(awk '{print int($1+0.5)}' <<< "$size_field")  # round
    local u; u=$(awk '{print toupper($2)}' <<< "$size_field")
    case "$u" in
      GB) echo "$n"; return ;;
      MB) echo 1; return ;;
      TB) echo $((n * 1024)); return ;;
    esac
  fi

  # 2. Stat the GGUF file
  if [[ -n "$MODEL_GGUF_PATH" && -f "$MODEL_GGUF_PATH" ]]; then
    local bytes; bytes=$(stat -f%z "$MODEL_GGUF_PATH" 2>/dev/null)
    [[ -n "$bytes" ]] && echo $((bytes / 1024 / 1024 / 1024 + 1)) && return
  fi

  # 3. Fallback to config
  echo "${MODEL_SIZE_GB:-16}"
}

# Refuse to proceed if not enough RAM for model + 4GB buffer
preflight_memory_check() {
  local needed_gb; needed_gb=$(get_model_size_gb)
  local buffer_gb=4
  local required=$((needed_gb + buffer_gb))
  local available; available=$(get_available_ram_gb)

  step "Memory preflight check"
  info "Model size:  ${needed_gb}GB (auto-detected)"
  info "Required:    ${required}GB (model + ${buffer_gb}GB buffer)"
  info "Available:   ${available}GB"

  if [[ "$available" -lt "$required" ]]; then
    error "INSUFFICIENT MEMORY — refusing to proceed"
    error "  Free up RAM by closing applications, or use a smaller model."
    error "  Current state risks system freeze. ABORTING for your safety."
    exit 1
  fi
  success "Memory check passed"
}

# Refuse to start Ollama if LM Studio still has models in RAM
check_no_competing_servers() {
  step "Checking for competing model servers"

  # LM Studio: check if any model loaded
  if [[ -x "$HOME/.lmstudio/bin/lms" ]]; then
    if "$HOME/.lmstudio/bin/lms" ps 2>/dev/null | grep -qE "GB|MB"; then
      error "LM Studio still has models loaded in RAM!"
      error "  This would cause double memory consumption."
      error "  Run: $HOME/.lmstudio/bin/lms unload --all"
      error "  Then: $HOME/.lmstudio/bin/lms server stop"
      exit 1
    fi
  fi

  success "No competing model servers running"
}

check_prerequisites() {
  step "Checking prerequisites"
  require_macos
  require_cmd podman "brew install podman"
  require_cmd jq    "brew install jq"
  require_cmd curl  "built-in on macOS"
  require_cmd ollama "brew install ollama"

  success "All prerequisites present"
}

# ---------- Install steps ----------
download_model() {
  step "Checking model: $MODEL_ID"

  # Already in Ollama's library?
  if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$MODEL_ID\(:latest\)\?"; then
    success "Model '$MODEL_ID' already available in Ollama"
    return
  fi

  # Disk-only check (no RAM impact) before any download/import
  if [[ -n "$MODEL_GGUF_PATH" ]]; then
    [[ -f "$MODEL_GGUF_PATH" ]] || die "MODEL_GGUF_PATH set but file not found: $MODEL_GGUF_PATH"
    info "Importing existing GGUF: $MODEL_GGUF_PATH"
    info "(no re-download — uses your local file)"

    local modelfile; modelfile=$(mktemp)
    cat > "$modelfile" <<EOF
FROM $MODEL_GGUF_PATH
PARAMETER num_ctx $MODEL_CONTEXT_LENGTH
EOF

    if ollama create "$MODEL_ID" -f "$modelfile"; then
      success "Model '$MODEL_ID' imported (context: $MODEL_CONTEXT_LENGTH tokens)"
    else
      rm -f "$modelfile"
      die "Import failed — check Ollama version supports this model architecture"
    fi
    rm -f "$modelfile"
  else
    info "Pulling $MODEL_ID from Ollama registry — this may take 10-20 minutes..."
    if ollama pull "$MODEL_ID"; then
      # Re-create with custom context length (registry default is usually 4096)
      local modelfile; modelfile=$(mktemp)
      cat > "$modelfile" <<EOF
FROM $MODEL_ID
PARAMETER num_ctx $MODEL_CONTEXT_LENGTH
EOF
      ollama create "${MODEL_ID}" -f "$modelfile" >/dev/null
      rm -f "$modelfile"
      success "Model '$MODEL_ID' downloaded (context: $MODEL_CONTEXT_LENGTH tokens)"
    else
      die "Pull failed — verify model name at https://ollama.com/library or set MODEL_GGUF_PATH"
    fi
  fi
}

setup_hostname() {
  [[ "$WEBUI_HOSTNAME" == "localhost" ]] && return

  step "Setting up custom hostname: $WEBUI_HOSTNAME"

  if grep -q "$WEBUI_HOSTNAME" /etc/hosts 2>/dev/null; then
    success "$WEBUI_HOSTNAME already in /etc/hosts"
  else
    info "Adding $WEBUI_HOSTNAME to /etc/hosts (requires sudo)"
    if echo "127.0.0.1 $WEBUI_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null 2>&1; then
      success "$WEBUI_HOSTNAME → 127.0.0.1 added to /etc/hosts"
    else
      warn "Could not write to /etc/hosts — run this once manually:"
      warn "  echo '127.0.0.1 $WEBUI_HOSTNAME' | sudo tee -a /etc/hosts"
    fi
  fi
}

setup_podman_machine() {
  step "Setting up Podman machine"

  if ! podman machine list --format '{{.Name}}' | grep -q .; then
    info "No machine found — initialising (cpus=$PODMAN_CPUS, mem=${PODMAN_MEMORY}MB)"
    podman machine init --cpus "$PODMAN_CPUS" --memory "$PODMAN_MEMORY"
  fi

  if ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running; then
    info "Starting machine..."
    podman machine start
  fi

  success "Podman machine running"
}

setup_container() {
  step "Setting up Open WebUI container"

  info "Pulling $WEBUI_IMAGE (this may take a minute)..."
  podman pull "$WEBUI_IMAGE"

  if podman container exists "$WEBUI_CONTAINER" 2>/dev/null; then
    info "Removing existing container"
    podman rm -f "$WEBUI_CONTAINER" >/dev/null
  fi

  info "Creating container..."
  podman run -d \
    --name "$WEBUI_CONTAINER" \
    --restart=always \
    -p "$WEBUI_PORT:8080" \
    -e OLLAMA_BASE_URL="http://host.containers.internal:$OLLAMA_PORT" \
    -e WEBUI_AUTH=true \
    -e ENABLE_OPENAI_API=false \
    -v "$WEBUI_VOLUME:/app/backend/data" \
    "$WEBUI_IMAGE" >/dev/null

  success "Container '$WEBUI_CONTAINER' running on :$WEBUI_PORT"
}

install_launch_agents() {
  step "Installing launchd auto-start agents"
  mkdir -p "$LAUNCH_AGENTS_DIR"

  local podman_bin; podman_bin="$(which podman)"
  local ollama_bin; ollama_bin="$(which ollama)"

  # --- Ollama server ---
  cat > "$OLLAMA_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.ollama.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>$ollama_bin serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key><string>127.0.0.1:$OLLAMA_PORT</string>
    <key>OLLAMA_FLASH_ATTENTION</key><string>$OLLAMA_FLASH_ATTENTION</string>
    <key>OLLAMA_KV_CACHE_TYPE</key><string>$OLLAMA_KV_CACHE_TYPE</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_OLLAMA</string>
  <key>StandardErrorPath</key><string>$LOG_OLLAMA_ERR</string>
</dict>
</plist>
EOF

  # --- Podman machine ---
  cat > "$PODMAN_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.podman.machine</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>$podman_bin machine start 2>/dev/null; exit 0</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_PODMAN</string>
  <key>StandardErrorPath</key><string>$LOG_PODMAN</string>
</dict>
</plist>
EOF

  # --- Open WebUI container (waits for machine) ---
  cat > "$WEBUI_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.openwebui</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>for i in {1..60}; do $podman_bin machine inspect --format '{{.State}}' 2>/dev/null | grep -q running && break; sleep 2; done; $podman_bin start $WEBUI_CONTAINER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_WEBUI</string>
  <key>StandardErrorPath</key><string>$LOG_WEBUI</string>
</dict>
</plist>
EOF

  for plist in "$OLLAMA_PLIST" "$PODMAN_PLIST" "$WEBUI_PLIST"; do
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load   "$plist"
  done

  success "Auto-start agents installed & loaded"
}

install_script() {
  step "Installing script to ~/.local/bin"
  local target="$HOME/.local/bin/local-ai"
  mkdir -p "$HOME/.local/bin"
  cp "$(realpath "$0")" "$target"
  chmod +x "$target"
  success "Installed to $target"
}

install_shell_aliases() {
  step "Installing shell aliases"

  local rc="$HOME/.zshrc"
  [[ -n "${FISH_VERSION:-}" ]] && rc="$HOME/.config/fish/config.fish"
  [[ ! -f "$rc" ]] && touch "$rc"

  # Ensure ~/.local/bin is in PATH
  if ! grep -q '.local/bin' "$rc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
  fi

  if grep -q "# --- Local AI Setup ---" "$rc"; then
    info "Aliases already present in $rc — skipping"
    return
  fi

  cat >> "$rc" <<EOF

# --- Local AI Setup ---
alias ai='open $WEBUI_URL'
alias ai-start='local-ai start'
alias ai-stop='local-ai stop'
alias ai-status='local-ai status'
alias ai-logs='podman logs -f $WEBUI_CONTAINER'
alias ai-update='local-ai update'
EOF

  success "Aliases added to $rc (open new shell to use)"
}

install_config() {
  step "Setting up configuration"
  mkdir -p "$CONFIG_DIR"

  if [[ -f "$CONFIG_FILE" ]]; then
    info "Config exists at $CONFIG_FILE — preserving"
    return
  fi

  cat > "$CONFIG_FILE" <<'CONF'
# Local AI Configuration
# Edit these values, then re-run: local-ai install
# Changes take effect on next install/restart.

# Model to use (Ollama naming, e.g. "gemma4-26b" or "llama3.1:8b")
# Browse models at https://ollama.com/library
MODEL_ID="gemma4-26b"

# Optional: fallback model size in GB if auto-detection fails.
# Normally not needed — script reads actual size from `ollama list` or GGUF file.
MODEL_SIZE_GB="16"

# Context length in tokens. Larger = more document/conversation history,
# but uses more KV-cache RAM. Safe ranges on 32GB:
#   8192   — minimal
#   32768  — recommended balance
#   65536  — only with q8_0 KV cache + flash attention
MODEL_CONTEXT_LENGTH="32768"

# Optional: import an existing GGUF file instead of pulling from Ollama registry.
# Useful if you already have models from LM Studio or HuggingFace.
# Leave empty to pull from the registry.
MODEL_GGUF_PATH=""

# Web UI access
# Set WEBUI_HOSTNAME to a custom name (e.g. "ai.local") for a friendly URL.
# The script will add it to /etc/hosts automatically (requires sudo once).
# Set WEBUI_PORT to 80 for a clean URL without port number.
WEBUI_HOSTNAME="localhost"
WEBUI_PORT="3000"
OLLAMA_PORT="11434"

# Ollama runtime tuning (defaults are safe — opt-in to aggressive settings)
# OLLAMA_FLASH_ATTENTION=1 enables faster attention but uses more RAM.
# OLLAMA_KV_CACHE_TYPE=q8_0 halves KV-cache memory at small quality cost.
OLLAMA_FLASH_ATTENTION="0"
OLLAMA_KV_CACHE_TYPE="f16"

# Podman VM resources (adjust for your hardware)
PODMAN_CPUS="6"
PODMAN_MEMORY="4096"
CONF

  success "Config created: $CONFIG_FILE"
}

# ---------- Commands ----------
cmd_install() {
  printf "${C_BOLD}Local AI Setup v%s${C_RESET}\n" "$SCRIPT_VERSION"
  check_prerequisites
  mkdir -p "$LOG_DIR"
  install_config
  download_model
  setup_hostname
  setup_podman_machine
  setup_container
  install_launch_agents
  install_script
  install_shell_aliases

  # SAFETY: verify enough RAM before pre-loading the model
  check_no_competing_servers
  preflight_memory_check

  # Pre-load model so first chat is instant
  step "Pre-loading model"
  info "Loading $MODEL_ID into RAM..."
  if ollama run "$MODEL_ID" "" </dev/null >/dev/null 2>&1; then
    success "Model loaded and ready"
  else
    warn "Could not pre-load — first chat will trigger the load"
  fi

  step "Done!"
  echo
  success "Open WebUI:  $WEBUI_URL"
  success "Ollama API:  http://localhost:$OLLAMA_PORT"
  echo
  info "First-time browser setup: create admin account, then select model in chat."
  echo
  info "Quick reference (open new shell first):"
  info "  ai           → Open chat in browser"
  info "  ai-stop      → Stop stack, free all resources"
  info "  ai-start     → Start stack again (with safety check)"
  info "  ai-status    → Health check"
}

cmd_stop() {
  step "Stopping Local AI stack"

  # Unload launch agents so they don't auto-restart
  for plist in "$WEBUI_PLIST" "$PODMAN_PLIST" "$OLLAMA_PLIST"; do
    launchctl unload "$plist" 2>/dev/null || true
  done
  info "Launch agents unloaded (no auto-restart)"

  # Stop container
  podman stop "$WEBUI_CONTAINER" 2>/dev/null || true
  info "Container stopped"

  # Stop Podman machine (frees VM memory)
  podman machine stop 2>/dev/null || true
  info "Podman machine stopped"

  # Stop Ollama (also unloads any loaded models from RAM)
  pkill -f "ollama serve" 2>/dev/null || true
  info "Ollama stopped (models unloaded from RAM)"

  success "Stack stopped — all resources freed"
  info "Run '$0 start' to bring it back up"
}

cmd_start() {
  step "Starting Local AI stack"

  # SAFETY: refuse to start if other model servers would compete for RAM
  check_no_competing_servers
  preflight_memory_check

  # Reload launch agents
  for plist in "$OLLAMA_PLIST" "$PODMAN_PLIST" "$WEBUI_PLIST"; do
    if [[ -f "$plist" ]]; then
      launchctl load "$plist" 2>/dev/null || true
    else
      warn "Agent not found: $plist — run '$0 install' first"
      return 1
    fi
  done

  # Wait for Ollama to be reachable
  info "Waiting for Ollama server..."
  for i in {1..15}; do
    curl -s --max-time 2 "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1 && break
    sleep 2
  done

  if curl -s --max-time 2 "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
    success "Ollama online"
  else
    warn "Ollama not responding yet — model pre-load skipped"
  fi

  # Pre-load model so first chat response is instant
  info "Pre-loading model: $MODEL_ID..."
  if ollama run "$MODEL_ID" "" </dev/null >/dev/null 2>&1; then
    success "Model loaded and ready"
  else
    warn "Could not pre-load model — first chat will be slow (~20s)"
  fi

  # Start Podman + container
  if podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running; then
    success "Podman machine running"
    podman start "$WEBUI_CONTAINER" 2>/dev/null || true
    success "Open WebUI starting at $WEBUI_URL"
  else
    info "Podman machine starting (may take 15-30 seconds)..."
    info "Open WebUI will start automatically once the machine is ready"
  fi

  success "Stack started — ready to use"
}

cmd_update() {
  step "Updating Open WebUI"
  podman pull "$WEBUI_IMAGE"
  podman restart "$WEBUI_CONTAINER"
  success "Restarted with latest stable image"
}

cmd_status() {
  printf "${C_BOLD}Local AI Status${C_RESET}\n\n"

  # Memory
  local available; available=$(get_available_ram_gb)
  printf "${C_BOLD}Memory${C_RESET}\n"
  local needed; needed=$(get_model_size_gb)
  info "${available}GB available (need ${needed}GB + 4GB buffer to load model)"

  # Ollama
  echo
  printf "${C_BOLD}Ollama Server${C_RESET} (:$OLLAMA_PORT)\n"
  if curl -s --max-time 2 "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
    local models; models=$(curl -s "http://localhost:$OLLAMA_PORT/api/tags" | jq -r '.models[].name' 2>/dev/null | sed 's/^/    /')
    success "Online"
    [[ -n "$models" ]] && echo "  Available models:" && echo "$models"
    local loaded; loaded=$(curl -s "http://localhost:$OLLAMA_PORT/api/ps" | jq -r '.models[].name' 2>/dev/null | sed 's/^/    /')
    [[ -n "$loaded" ]] && echo "  Loaded in RAM:" && echo "$loaded"
  else
    error "Offline — check: tail $LOG_OLLAMA_ERR"
  fi

  # Podman machine
  echo
  printf "${C_BOLD}Podman Machine${C_RESET}\n"
  local machine_state; machine_state=$(podman machine inspect --format '{{.State}}' 2>/dev/null || echo "not found")
  if [[ "$machine_state" == "running" ]]; then
    success "Running"
  else
    error "State: $machine_state"
  fi

  # Container
  echo
  printf "${C_BOLD}Open WebUI Container${C_RESET} (:$WEBUI_PORT)\n"
  if podman ps --filter "name=$WEBUI_CONTAINER" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
    success "Running — $(podman ps --filter name=$WEBUI_CONTAINER --format '{{.Status}}')"
    if curl -s --max-time 2 -o /dev/null -w "%{http_code}" "$WEBUI_URL" | grep -qE '2..|3..'; then
      success "HTTP responding at $WEBUI_URL"
    else
      warn "Container up but HTTP not responding yet"
    fi
  else
    error "Not running — check: podman logs $WEBUI_CONTAINER"
  fi

  # Launch agents
  echo
  printf "${C_BOLD}Launch Agents${C_RESET}\n"
  for agent in ai.ollama.server io.podman.machine ai.openwebui; do
    if launchctl list | grep -q "$agent"; then
      success "$agent loaded"
    else
      error "$agent not loaded"
    fi
  done
}

cmd_doctor() {
  printf "${C_BOLD}Running diagnostics${C_RESET}\n\n"

  local needed; needed=$(get_model_size_gb)
  info "Available memory: $(get_available_ram_gb)GB (need $((needed + 4))GB to load model)"

  echo
  info "Checking port conflicts..."
  for port in "$OLLAMA_PORT" "$WEBUI_PORT"; do
    local pid; pid=$(lsof -ti ":$port" 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
      local proc; proc=$(ps -p "$pid" -o comm= 2>/dev/null)
      info "  Port $port: in use by $proc (pid $pid)"
    else
      warn "  Port $port: nothing listening"
    fi
  done

  echo
  info "Recent Ollama errors (last 10 lines):"
  [[ -f "$LOG_OLLAMA_ERR" ]] && tail -10 "$LOG_OLLAMA_ERR" | sed 's/^/  /' || echo "  (no log yet)"

  echo
  info "Recent container logs (last 20 lines):"
  podman logs --tail 20 "$WEBUI_CONTAINER" 2>&1 | sed 's/^/  /' || echo "  (container not running)"

  echo
  info "Podman connection:"
  podman system connection list 2>&1 | sed 's/^/  /'

  echo
  info "Disk space:"
  df -h / | tail -1 | sed 's/^/  /'
}

cmd_logs() {
  info "Tailing all logs (Ctrl-C to exit)..."
  tail -f "$LOG_OLLAMA" "$LOG_OLLAMA_ERR" "$LOG_WEBUI" "$LOG_PODMAN" 2>/dev/null
}

cmd_uninstall() {
  step "Uninstalling Local AI stack"
  warn "This will remove: launch agents, container, container volume."
  warn "LM Studio app, downloaded models, and WebUI data volume will be preserved unless you pass --purge"
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Aborted"; exit 0; }

  for plist in "$OLLAMA_PLIST" "$PODMAN_PLIST" "$WEBUI_PLIST"; do
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
  done
  success "Launch agents removed"

  podman rm -f "$WEBUI_CONTAINER" 2>/dev/null || true
  success "Container removed"

  if [[ "${1:-}" == "--purge" ]]; then
    podman volume rm "$WEBUI_VOLUME" 2>/dev/null || true
    warn "Volume '$WEBUI_VOLUME' (chats, settings) purged"
  else
    info "Volume '$WEBUI_VOLUME' preserved (use --purge to delete)"
  fi

  info "Shell aliases in ~/.zshrc left in place — remove the '# --- Local AI Setup ---' block manually if desired"
  success "Uninstall complete"
}

cmd_backup() {
  step "Backing up Open WebUI data"
  local backup_dir="${1:-$HOME/local-ai-backups}"
  local timestamp; timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$backup_dir/openwebui_backup_$timestamp.tar.gz"

  mkdir -p "$backup_dir"

  if ! podman ps --filter "name=$WEBUI_CONTAINER" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
    die "Container not running — cannot export volume"
  fi

  info "Exporting volume '$WEBUI_VOLUME'..."
  podman volume export "$WEBUI_VOLUME" | gzip > "$backup_file"

  success "Backup saved: $backup_file"
  info "Size: $(du -h "$backup_file" | cut -f1)"
}

cmd_restore() {
  local backup_file="${1:-}"
  [[ -z "$backup_file" ]] && die "Usage: $0 restore <backup-file.tar.gz>"
  [[ -f "$backup_file" ]] || die "File not found: $backup_file"

  step "Restoring Open WebUI data"
  warn "This will REPLACE all current chats, settings, and documents."
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Aborted"; exit 0; }

  info "Stopping container..."
  podman stop "$WEBUI_CONTAINER" 2>/dev/null || true

  info "Importing volume..."
  gunzip -c "$backup_file" | podman volume import "$WEBUI_VOLUME" -

  info "Restarting container..."
  podman start "$WEBUI_CONTAINER"

  success "Restore complete — container restarted"
}

# ---------- Dispatcher ----------
usage() {
  cat <<EOF
${C_BOLD}local-ai.sh${C_RESET} — Hassle-free local AI stack (v$SCRIPT_VERSION)

Usage:
  $0 install              First-time setup (incl. model download)
  $0 start                Start all services
  $0 stop                 Stop all services (frees RAM + CPU)
  $0 update               Pull latest stable Open WebUI image
  $0 status               Health check
  $0 doctor               Diagnose problems
  $0 logs                 Tail all logs
  $0 backup [dir]         Backup chats & settings (default: ~/local-ai-backups)
  $0 restore <file>       Restore from backup archive
  $0 uninstall [--purge]  Remove everything (--purge also deletes WebUI data)

Environment variables (all overridable via config file):
  MODEL_ID=$MODEL_ID                Ollama model to use
  MODEL_SIZE_GB=$MODEL_SIZE_GB                       Estimated size for safety check
  MODEL_GGUF_PATH=...               Optional: import GGUF instead of pulling
  WEBUI_HOSTNAME=$WEBUI_HOSTNAME       Custom hostname (e.g. ai.local)
  WEBUI_PORT=$WEBUI_PORT                  Open WebUI port (80 for clean URL)
  OLLAMA_PORT=$OLLAMA_PORT             Ollama API port
  PODMAN_CPUS=$PODMAN_CPUS                   Podman machine CPU count
  PODMAN_MEMORY=$PODMAN_MEMORY             Podman machine memory (MB)

Config file: $CONFIG_FILE
EOF
}

main() {
  case "${1:-}" in
    install)   cmd_install ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    update)    cmd_update ;;
    status)    cmd_status ;;
    doctor)    cmd_doctor ;;
    logs)      cmd_logs ;;
    backup)    shift; cmd_backup "${1:-}" ;;
    restore)   shift; cmd_restore "${1:-}" ;;
    uninstall) shift; cmd_uninstall "${1:-}" ;;
    -h|--help|help|"") usage ;;
    *) error "Unknown command: $1"; usage; exit 1 ;;
  esac
}

main "$@"
