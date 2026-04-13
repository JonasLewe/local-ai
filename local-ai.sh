#!/usr/bin/env bash
# local-ai.sh — Hassle-free local AI stack for macOS (Apple Silicon)
# Stack: LM Studio (headless) + Open WebUI (Podman) + launchd auto-start
#
# Usage:
#   ./local-ai.sh install     # First-time setup
#   ./local-ai.sh update      # Pull latest Open WebUI dev image
#   ./local-ai.sh status      # Health check all components
#   ./local-ai.sh doctor      # Diagnose common problems
#   ./local-ai.sh uninstall   # Remove everything (keeps LM Studio + models)
#   ./local-ai.sh logs        # Tail all relevant logs
#
# Requirements: macOS 13+, Apple Silicon, LM Studio installed, Homebrew

set -euo pipefail

# ---------- Configuration ----------
readonly SCRIPT_VERSION="1.0.0"
readonly LMS_PORT="${LMS_PORT:-1234}"
readonly WEBUI_PORT="${WEBUI_PORT:-3000}"
readonly WEBUI_IMAGE="ghcr.io/open-webui/open-webui:dev"
readonly WEBUI_CONTAINER="open-webui"
readonly WEBUI_VOLUME="open-webui"
readonly PODMAN_CPUS="${PODMAN_CPUS:-4}"
readonly PODMAN_MEMORY="${PODMAN_MEMORY:-4096}"

readonly LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
readonly LMS_PLIST="$LAUNCH_AGENTS_DIR/ai.lmstudio.server.plist"
readonly PODMAN_PLIST="$LAUNCH_AGENTS_DIR/io.podman.machine.plist"
readonly WEBUI_PLIST="$LAUNCH_AGENTS_DIR/ai.openwebui.plist"

readonly LOG_LMS="/tmp/lms.out.log"
readonly LOG_LMS_ERR="/tmp/lms.err.log"
readonly LOG_PODMAN="/tmp/podman-machine.log"
readonly LOG_WEBUI="/tmp/openwebui.log"

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

check_prerequisites() {
  step "Checking prerequisites"
  require_macos
  require_cmd podman "brew install podman"
  require_cmd jq    "brew install jq"
  require_cmd curl  "built-in on macOS"

  [[ -d "/Applications/LM Studio.app" ]] || \
    die "LM Studio not found in /Applications. Download from https://lmstudio.ai"

  [[ -x "$HOME/.lmstudio/bin/lms" ]] || {
    warn "LM Studio CLI not bootstrapped — attempting bootstrap"
    "$HOME/.lmstudio/bin/lms" bootstrap 2>/dev/null || \
      die "Could not bootstrap 'lms'. Open LM Studio.app once manually, then re-run."
  }

  success "All prerequisites present"
}

# ---------- Install steps ----------
configure_lms() {
  step "Configuring LM Studio headless mode"
  local lms="$HOME/.lmstudio/bin/lms"

  "$lms" server start --port "$LMS_PORT" >/dev/null 2>&1 || true
  sleep 2
  "$lms" server set --jit-loading true    >/dev/null
  "$lms" server set --jit-auto-evict true >/dev/null
  "$lms" server stop >/dev/null 2>&1 || true

  success "JIT loading enabled, auto-evict on"
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
    --add-host=host.docker.internal:host-gateway \
    -p "$WEBUI_PORT:8080" \
    -e OPENAI_API_BASE_URL="http://host.docker.internal:$LMS_PORT/v1" \
    -e OPENAI_API_KEY=lm-studio \
    -e WEBUI_AUTH=true \
    -e ENABLE_OLLAMA_API=false \
    -v "$WEBUI_VOLUME:/app/backend/data" \
    "$WEBUI_IMAGE" >/dev/null

  success "Container '$WEBUI_CONTAINER' running on :$WEBUI_PORT"
}

install_launch_agents() {
  step "Installing launchd auto-start agents"
  mkdir -p "$LAUNCH_AGENTS_DIR"

  local podman_bin; podman_bin="$(which podman)"

  # --- LM Studio server ---
  cat > "$LMS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.lmstudio.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>$HOME/.lmstudio/bin/lms server start --port $LMS_PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_LMS</string>
  <key>StandardErrorPath</key><string>$LOG_LMS_ERR</string>
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

  for plist in "$LMS_PLIST" "$PODMAN_PLIST" "$WEBUI_PLIST"; do
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load   "$plist"
  done

  success "Auto-start agents installed & loaded"
}

install_shell_aliases() {
  step "Installing shell aliases"

  local rc="$HOME/.zshrc"
  [[ -n "${FISH_VERSION:-}" ]] && rc="$HOME/.config/fish/config.fish"
  [[ ! -f "$rc" ]] && touch "$rc"

  if grep -q "# --- Local AI Setup ---" "$rc"; then
    info "Aliases already present in $rc — skipping"
    return
  fi

  cat >> "$rc" <<'EOF'

# --- Local AI Setup ---
alias webui='open http://localhost:3000'
alias webui-logs='podman logs -f open-webui'
alias webui-restart='podman restart open-webui'
alias webui-update='podman pull ghcr.io/open-webui/open-webui:dev && podman restart open-webui'
alias llm-logs='tail -f /tmp/lms.out.log'
alias llm-status='~/bin/local-ai status 2>/dev/null || echo "run local-ai.sh status"'
EOF

  success "Aliases added to $rc (open new shell to use)"
}

# ---------- Commands ----------
cmd_install() {
  printf "${C_BOLD}Local AI Setup v%s${C_RESET}\n" "$SCRIPT_VERSION"
  check_prerequisites
  configure_lms
  setup_podman_machine
  setup_container
  install_launch_agents
  install_shell_aliases

  step "Done!"
  echo
  success "Open WebUI:  http://localhost:$WEBUI_PORT"
  success "LM Studio:   http://localhost:$LMS_PORT/v1"
  echo
  info "First-time browser setup: create admin account, then select model in chat."
  info "Verify setup:  ./local-ai.sh status"
}

cmd_update() {
  step "Updating Open WebUI"
  podman pull "$WEBUI_IMAGE"
  podman restart "$WEBUI_CONTAINER"
  success "Restarted with latest dev image"
}

cmd_status() {
  printf "${C_BOLD}Local AI Status${C_RESET}\n\n"

  # LM Studio
  printf "${C_BOLD}LM Studio Server${C_RESET} (:$LMS_PORT)\n"
  if curl -s --max-time 2 "http://localhost:$LMS_PORT/v1/models" >/dev/null 2>&1; then
    local models; models=$(curl -s "http://localhost:$LMS_PORT/v1/models" | jq -r '.data[].id' 2>/dev/null | sed 's/^/    /')
    success "Online"
    [[ -n "$models" ]] && echo "  Available models:" && echo "$models"
  else
    error "Offline — check: tail $LOG_LMS_ERR"
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
    if curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://localhost:$WEBUI_PORT" | grep -qE '2..|3..'; then
      success "HTTP responding at http://localhost:$WEBUI_PORT"
    else
      warn "Container up but HTTP not responding yet"
    fi
  else
    error "Not running — check: podman logs $WEBUI_CONTAINER"
  fi

  # Launch agents
  echo
  printf "${C_BOLD}Launch Agents${C_RESET}\n"
  for agent in ai.lmstudio.server io.podman.machine ai.openwebui; do
    if launchctl list | grep -q "$agent"; then
      success "$agent loaded"
    else
      error "$agent not loaded"
    fi
  done
}

cmd_doctor() {
  printf "${C_BOLD}Running diagnostics${C_RESET}\n\n"

  info "Checking port conflicts..."
  for port in "$LMS_PORT" "$WEBUI_PORT"; do
    local pid; pid=$(lsof -ti ":$port" 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
      local proc; proc=$(ps -p "$pid" -o comm= 2>/dev/null)
      info "  Port $port: in use by $proc (pid $pid)"
    else
      warn "  Port $port: nothing listening"
    fi
  done

  echo
  info "Recent LM Studio errors (last 10 lines):"
  [[ -f "$LOG_LMS_ERR" ]] && tail -10 "$LOG_LMS_ERR" | sed 's/^/  /' || echo "  (no log yet)"

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
  tail -f "$LOG_LMS" "$LOG_LMS_ERR" "$LOG_WEBUI" "$LOG_PODMAN" 2>/dev/null
}

cmd_uninstall() {
  step "Uninstalling Local AI stack"
  warn "This will remove: launch agents, container, container volume."
  warn "LM Studio app, downloaded models, and WebUI data volume will be preserved unless you pass --purge"
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "Aborted"; exit 0; }

  for plist in "$LMS_PLIST" "$PODMAN_PLIST" "$WEBUI_PLIST"; do
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

# ---------- Dispatcher ----------
usage() {
  cat <<EOF
${C_BOLD}local-ai.sh${C_RESET} — Hassle-free local AI stack (v$SCRIPT_VERSION)

Usage:
  $0 install              First-time setup
  $0 update               Pull latest Open WebUI dev image
  $0 status               Health check
  $0 doctor               Diagnose problems
  $0 logs                 Tail all logs
  $0 uninstall [--purge]  Remove everything (--purge also deletes WebUI data)

Environment variables:
  LMS_PORT=$LMS_PORT              LM Studio server port
  WEBUI_PORT=$WEBUI_PORT            Open WebUI port
  PODMAN_CPUS=$PODMAN_CPUS             Podman machine CPU count
  PODMAN_MEMORY=$PODMAN_MEMORY       Podman machine memory (MB)
EOF
}

main() {
  case "${1:-}" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    status)    cmd_status ;;
    doctor)    cmd_doctor ;;
    logs)      cmd_logs ;;
    uninstall) shift; cmd_uninstall "${1:-}" ;;
    -h|--help|help|"") usage ;;
    *) error "Unknown command: $1"; usage; exit 1 ;;
  esac
}

main "$@"
