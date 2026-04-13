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

# Ports
readonly OLLAMA_PORT="${OLLAMA_PORT:-11434}"
readonly WEBUI_PORT="${WEBUI_PORT:-3000}"
readonly WEBUI_HOSTNAME="${WEBUI_HOSTNAME:-localhost}"

# Container
# In regulated environments, pin this to a version/digest instead of `latest`.
readonly WEBUI_IMAGE="${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:latest}"
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

# Ollama runtime tuning (optimized defaults for Apple Silicon 32GB systems)
readonly OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
readonly OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
readonly OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-24h}"
readonly OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
readonly OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"

# --- RAG / Document search defaults ---
# bge-m3: multilingual (100+ langs incl. strong German), 8K ctx, 1.2GB — best
# general-purpose embedding for mixed-language document collections.
# Alternative: "nomic-embed-text" (English-first, 274MB, faster).
readonly EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}"
# Reranker is disabled by default for strict local-only operation.
# Set this to e.g. BAAI/bge-reranker-v2-m3 if you accept one-time HF download.
readonly RERANKING_MODEL="${RERANKING_MODEL:-}"
readonly RAG_TOP_K="${RAG_TOP_K:-20}"
readonly RAG_TOP_K_RERANKER="${RAG_TOP_K_RERANKER:-5}"
readonly RAG_CHUNK_SIZE="${RAG_CHUNK_SIZE:-1500}"
readonly RAG_CHUNK_OVERLAP="${RAG_CHUNK_OVERLAP:-200}"

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

# Three-tier memory check (macOS unified memory, mmap-backed model loads):
#   available >= model + 2GB  → comfortable, proceed silently
#   available >= model - 4GB  → workable, macOS will swap <=4GB inactive pages, warn
#   available <  model - 4GB  → too tight, heavy swap would thrash, refuse hard
# The 4GB swap tolerance matches what LM Studio's users routinely ran on 32GB
# systems without issue. The REAL crash safety is check_no_competing_servers —
# RAM math alone can't catch two model servers loading the same model.
preflight_memory_check() {
  local needed_gb; needed_gb=$(get_model_size_gb)
  local comfortable=$((needed_gb + 2))
  local minimum=$((needed_gb - 4))
  local available; available=$(get_available_ram_gb)

  step "Memory preflight check"
  info "Model size:  ${needed_gb}GB (auto-detected)"
  info "Available:   ${available}GB free + inactive"

  if [[ "$available" -lt "$minimum" ]]; then
    error "INSUFFICIENT MEMORY — refusing to proceed"
    error "  Available (${available}GB) is far below model size (${needed_gb}GB)."
    error "  Even with macOS swap the system would thrash. ABORTING."
    error "  Free up RAM by closing applications, or use a smaller model."
    exit 1
  elif [[ "$available" -lt "$comfortable" ]]; then
    warn "Tight: ${available}GB available, ${needed_gb}GB needed"
    warn "  macOS will swap some inactive pages — may slow the first load briefly."
    warn "  Proceeding (safe for deficits up to 4GB)."
  else
    success "Memory check passed (${available}GB available, ${needed_gb}GB needed)"
  fi
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

# Ensure Ollama server is reachable on $OLLAMA_PORT. If not, start it in the
# background with the configured env vars. Used during install/start before
# any command that talks to the Ollama API (list, pull, create, run).
ensure_ollama_running() {
  if curl -sf --max-time 1 "http://127.0.0.1:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
    return 0
  fi

  step "Starting Ollama server"
  mkdir -p "$LOG_DIR"
  # Use `env` to set vars for the child only — OLLAMA_* are readonly in this shell
  nohup env \
    OLLAMA_HOST="127.0.0.1:$OLLAMA_PORT" \
    OLLAMA_FLASH_ATTENTION="$OLLAMA_FLASH_ATTENTION" \
    OLLAMA_KV_CACHE_TYPE="$OLLAMA_KV_CACHE_TYPE" \
    OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" \
    OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED_MODELS" \
    OLLAMA_NUM_PARALLEL="$OLLAMA_NUM_PARALLEL" \
    ollama serve >>"$LOG_OLLAMA" 2>>"$LOG_OLLAMA_ERR" &
  disown 2>/dev/null || true

  local _
  for _ in {1..20}; do
    if curl -sf --max-time 1 "http://127.0.0.1:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
      success "Ollama server reachable on 127.0.0.1:$OLLAMA_PORT"
      return 0
    fi
    sleep 1
  done

  error "Ollama server failed to start within 20s"
  error "  Check logs: $LOG_OLLAMA_ERR"
  exit 1
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


# ---------- Stop Ollama ----------
stop_ollama_listener() {
  local pid=""
  pid="$(lsof -nP -iTCP:"$OLLAMA_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"

  if [[ -n "$pid" ]] && ps -p "$pid" -o comm= 2>/dev/null | grep -q 'ollama'; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
}

# ---------- Install steps ----------
download_embedding_model() {
  step "Checking embedding model: $EMBEDDING_MODEL"
  if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Eq "^(${EMBEDDING_MODEL}|${EMBEDDING_MODEL}:latest)$"; then
    success "Embedding model '$EMBEDDING_MODEL' already available"
    return
  fi
  info "Pulling $EMBEDDING_MODEL from Ollama registry (used for document search)..."
  if ollama pull "$EMBEDDING_MODEL"; then
    success "Embedding model '$EMBEDDING_MODEL' ready"
  else
    die "Pull failed — verify model name at https://ollama.com/library"
  fi
}

download_model() {
  step "Checking model: $MODEL_ID"

  if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Eq "^(${MODEL_ID}|${MODEL_ID}:latest)$"; then

    # Check whether the existing model's num_ctx matches the configured value.
    # If it does, skip re-import. If not, rebuild the Modelfile with the new ctx.
    local current_ctx
    current_ctx=$(ollama show "$MODEL_ID" --modelfile 2>/dev/null \
      | awk '/^PARAMETER +num_ctx/ {print $3; exit}')
    if [[ "$current_ctx" == "$MODEL_CONTEXT_LENGTH" ]]; then
      success "Model '$MODEL_ID' already available (context: $current_ctx tokens)"
      return
    fi
    info "Model exists but num_ctx mismatch: current=$current_ctx, configured=$MODEL_CONTEXT_LENGTH"
    info "Re-creating Modelfile to apply new context length (no re-download)"

    # Re-create from existing Ollama-stored model — fast, disk-only operation
    local modelfile; modelfile=$(mktemp)
    cat > "$modelfile" <<EOF
FROM $MODEL_ID
PARAMETER num_ctx $MODEL_CONTEXT_LENGTH
EOF
    if ollama create "$MODEL_ID" -f "$modelfile" >/dev/null; then
      success "Model '$MODEL_ID' context updated to $MODEL_CONTEXT_LENGTH tokens"
    else
      rm -f "$modelfile"
      die "Re-create failed — check 'ollama show $MODEL_ID'"
    fi
    rm -f "$modelfile"
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
  local -a webui_env=(
    -e OLLAMA_BASE_URL="http://host.containers.internal:$OLLAMA_PORT"
    -e WEBUI_AUTH=true
    -e ENABLE_OPENAI_API=false
    -e RAG_EMBEDDING_ENGINE=ollama
    -e RAG_EMBEDDING_MODEL="$EMBEDDING_MODEL"
    -e RAG_OLLAMA_BASE_URL="http://host.containers.internal:$OLLAMA_PORT"
    -e RAG_TOP_K="$RAG_TOP_K"
    -e CHUNK_SIZE="$RAG_CHUNK_SIZE"
    -e CHUNK_OVERLAP="$RAG_CHUNK_OVERLAP"
  )

  if [[ -n "$RERANKING_MODEL" ]]; then
    webui_env+=(
      -e ENABLE_RAG_HYBRID_SEARCH=true
      -e RAG_RERANKING_MODEL="$RERANKING_MODEL"
      -e RAG_TOP_K_RERANKER="$RAG_TOP_K_RERANKER"
    )
  else
    webui_env+=(
      -e ENABLE_RAG_HYBRID_SEARCH=false
      -e RAG_TOP_K_RERANKER=0
    )
    info "Reranker disabled (strict-local default). Set RERANKING_MODEL to enable."
  fi

  podman run -d \
    --name "$WEBUI_CONTAINER" \
    --restart=always \
    --security-opt no-new-privileges \
    --cap-drop all \
	-p "127.0.0.1:$WEBUI_PORT:8080" \
    "${webui_env[@]}" \
    -v "$WEBUI_VOLUME:/app/backend/data" \
    "$WEBUI_IMAGE" >/dev/null

  success "Container '$WEBUI_CONTAINER' running on :$WEBUI_PORT"
}

# Enforce RAG config in sqlite. Open WebUI has "PersistentConfig" — env vars
# only apply on first container creation with a fresh volume. For upgrades
# (volume already has a config row), env vars are ignored. This function
# patches the sqlite config so settings are always current after install.
configure_webui_rag() {
  step "Applying RAG configuration to Open WebUI"

  # Wait for sqlite config row to exist (fresh installs init it on first boot)
  local _
  for _ in {1..30}; do
    if podman exec "$WEBUI_CONTAINER" test -s /app/backend/data/webui.db 2>/dev/null \
      && podman exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
r = c.execute(\"SELECT count(*) FROM config\").fetchone()
c.close()
exit(0 if r[0] > 0 else 1)
" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  # Patch the config row
  local py_script; py_script=$(mktemp)
  cat > "$py_script" <<PYEOF
import sqlite3, json, sys
DB = "/app/backend/data/webui.db"
c = sqlite3.connect(DB)
row = c.execute("SELECT id, data FROM config ORDER BY id DESC LIMIT 1").fetchone()
if not row:
    print("no config row yet — skipping (will apply on next install run)")
    sys.exit(0)
cfg_id, raw = row
cfg = json.loads(raw)
rag = cfg.setdefault("rag", {})
rag.update({
    "embedding_engine": "ollama",
    "embedding_model": "$EMBEDDING_MODEL",
    "top_k": $RAG_TOP_K,
    "chunk_size": $RAG_CHUNK_SIZE,
    "chunk_overlap": $RAG_CHUNK_OVERLAP,
})
if "$RERANKING_MODEL":
    rag["enable_hybrid_search"] = True
    rag["reranking_model"] = "$RERANKING_MODEL"
    rag["top_k_reranker"] = $RAG_TOP_K_RERANKER
else:
    rag["enable_hybrid_search"] = False
    rag["top_k_reranker"] = 0
    rag.pop("reranking_model", None)
# Ensure Ollama endpoint is set for embeddings
rag.setdefault("ollama", {})["url"] = "http://host.containers.internal:$OLLAMA_PORT"
c.execute("UPDATE config SET data = ? WHERE id = ?", (json.dumps(cfg), cfg_id))
c.commit()
c.close()
print("ok")
PYEOF
  podman cp "$py_script" "$WEBUI_CONTAINER:/tmp/patch_rag.py" >/dev/null
  rm -f "$py_script"

  if podman exec "$WEBUI_CONTAINER" python3 /tmp/patch_rag.py >/dev/null 2>&1; then
    # Restart so in-memory config is refreshed from sqlite
    podman restart "$WEBUI_CONTAINER" >/dev/null
    success "RAG config applied: $EMBEDDING_MODEL + reranker, top_k=$RAG_TOP_K/$RAG_TOP_K_RERANKER, chunks=${RAG_CHUNK_SIZE}/${RAG_CHUNK_OVERLAP}"
  else
    warn "Could not patch RAG config — env vars from container creation still apply for fresh installs"
  fi
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
    <key>OLLAMA_KEEP_ALIVE</key><string>$OLLAMA_KEEP_ALIVE</string>
    <key>OLLAMA_MAX_LOADED_MODELS</key><string>$OLLAMA_MAX_LOADED_MODELS</string>
    <key>OLLAMA_NUM_PARALLEL</key><string>$OLLAMA_NUM_PARALLEL</string>
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

  # Stop any foreground `ollama serve` started by ensure_ollama_running
  # so launchd can bind the port without a conflict.
  stop_ollama_listener

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

  # Remove any previous Local AI block (so URL/port changes apply on re-install)
  if grep -q "# --- Local AI Setup ---" "$rc"; then
    local tmp; tmp=$(mktemp)
    awk '
      /^# --- Local AI Setup ---$/ { skip=1; next }
      skip && /^# --- End Local AI Setup ---$/ { skip=0; next }
      !skip
    ' "$rc" > "$tmp" && mv "$tmp" "$rc"
    info "Removed old aliases from $rc"
  fi

  cat >> "$rc" <<EOF

# --- Local AI Setup ---
alias ai='open $WEBUI_URL'
alias ai-start='local-ai start'
alias ai-stop='local-ai stop'
alias ai-status='local-ai status'
alias ai-logs='podman logs -f $WEBUI_CONTAINER'
alias ai-update='local-ai update'
# --- End Local AI Setup ---
EOF

  success "Aliases written to $rc (open new shell to use)"
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
# Pin this in regulated environments (tag or digest) instead of relying on latest.
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:latest"

# Ollama runtime tuning for Apple Silicon 32GB:
# Flash Attention + q8_0 KV cache is the best throughput/memory balance.
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KV_CACHE_TYPE="q8_0"
# Keep model in RAM for fast first-token latency.
OLLAMA_KEEP_ALIVE="24h"
# Prevent accidental double-loading of multiple large models.
OLLAMA_MAX_LOADED_MODELS="1"
# Single interactive session gets best latency with parallel=1.
OLLAMA_NUM_PARALLEL="1"

# Podman VM resources (adjust for your hardware)
PODMAN_CPUS="6"
PODMAN_MEMORY="4096"

# --- RAG / Document search (Knowledge Bases in Open WebUI) ---
# Embedding model for document chunks. bge-m3 is multilingual (100+ langs,
# strong German); nomic-embed-text is lighter (274MB) but English-first.
EMBEDDING_MODEL="bge-m3"

# Reranker is disabled by default for strict local-only operation.
# Set to e.g. BAAI/bge-reranker-v2-m3 if you accept one-time HuggingFace download.
RERANKING_MODEL=""

# Retrieval tuning: vector search pulls TOP_K candidates, reranker picks the
# best TOP_K_RERANKER from those. Raising TOP_K improves recall, costs latency.
RAG_TOP_K="20"
RAG_TOP_K_RERANKER="5"

# Chunk size / overlap for document splitting. 1500/200 works well for typical
# PDFs and docs. Smaller chunks = more precise retrieval, more re-ranker work.
RAG_CHUNK_SIZE="1500"
RAG_CHUNK_OVERLAP="200"
CONF

  success "Config created: $CONFIG_FILE"
}

# ---------- Commands ----------
cmd_install() {
  printf "${C_BOLD}Local AI Setup v%s${C_RESET}\n" "$SCRIPT_VERSION"
  check_prerequisites
  mkdir -p "$LOG_DIR"
  install_config

  # SAFETY: refuse if another model server (LM Studio) already holds RAM
  check_no_competing_servers

  # download_model / pre-load need a reachable Ollama API — start it now.
  # install_launch_agents will later take over (it kills this process first).
  ensure_ollama_running

  download_model
  download_embedding_model
  setup_hostname
  setup_podman_machine
  setup_container
  configure_webui_rag
  install_launch_agents
  install_script
  install_shell_aliases

  # RAM check before pre-loading the 16GB model
  preflight_memory_check

  # launchd started Ollama asynchronously — wait until API is reachable again
  ensure_ollama_running

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
  stop_ollama_listener
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
  for _ in {1..15}; do
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
  success "Restarted with configured image: $WEBUI_IMAGE"
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
    # lsof exits 1 when no process is listening, which is expected here.
    local pid; pid=$(lsof -ti ":$port" 2>/dev/null | head -1 || true)
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
  if [[ -n "$RERANKING_MODEL" ]]; then
    warn "Reranker enabled ($RERANKING_MODEL): first RAG use may trigger HuggingFace download."
  else
    info "Reranker disabled: no HuggingFace download during RAG."
  fi

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
  $0 update               Pull configured Open WebUI image
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
  WEBUI_IMAGE=$WEBUI_IMAGE         Open WebUI image tag/digest
  WEBUI_HOSTNAME=$WEBUI_HOSTNAME       Custom hostname (e.g. ai.local)
  WEBUI_PORT=$WEBUI_PORT                  Open WebUI port (80 for clean URL)
  OLLAMA_PORT=$OLLAMA_PORT             Ollama API port
  OLLAMA_KEEP_ALIVE=$OLLAMA_KEEP_ALIVE         Keep model in RAM between requests
  OLLAMA_MAX_LOADED_MODELS=$OLLAMA_MAX_LOADED_MODELS   Max concurrently loaded models
  OLLAMA_NUM_PARALLEL=$OLLAMA_NUM_PARALLEL           Concurrent requests per model
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
