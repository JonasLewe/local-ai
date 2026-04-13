#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT_DIR/local-ai.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  printf 'PASS %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected output to contain: %s\n' "$needle" >&2
    return 1
  fi
}

create_mock_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat >"$bin_dir/mockcmd" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cmd="$(basename "$0")"

case "$cmd" in
  uname)
    case "${1:-}" in
      -s) echo "Darwin" ;;
      -m) echo "arm64" ;;
      *) /usr/bin/uname "$@" ;;
    esac
    ;;

  vm_stat)
    cat <<'EOF_VM'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               600000.
Pages active:                             200000.
Pages inactive:                           700000.
EOF_VM
    ;;

  curl)
    if [[ " $* " == *" %{http_code} "* ]]; then
      printf '200'
      exit 0
    fi
    exit 0
    ;;

  ollama)
    sub="${1:-}"
    case "$sub" in
      list)
        cat <<'EOF_OLLAMA_LIST'
NAME            ID              SIZE      MODIFIED
gemma4-26b      abcdef123       16 GB     1 day ago
bge-m3          123abcdef       1.2 GB    1 day ago
EOF_OLLAMA_LIST
        ;;
      show)
        echo "PARAMETER num_ctx 32768"
        ;;
      pull|create|run|serve)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;

  podman)
    sub="${1:-}"
    case "$sub" in
      machine)
        case "${2:-}" in
          list) echo "podman-machine-default" ;;
          inspect) echo "running" ;;
          start|stop|init) exit 0 ;;
          *) exit 0 ;;
        esac
        ;;
      container)
        case "${2:-}" in
          exists) exit 1 ;;
          *) exit 0 ;;
        esac
        ;;
      pull|rm|cp|restart|start|stop)
        exit 0
        ;;
      run)
        echo "mock-container-id"
        exit 0
        ;;
      exec)
        exit 0
        ;;
      logs)
        echo "mock log line"
        exit 0
        ;;
      ps)
        exit 1
        ;;
      system)
        if [[ "${2:-}" == "connection" && "${3:-}" == "list" ]]; then
          echo "default*  ssh://core@127.0.0.1:12345"
        fi
        ;;
      volume)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;

  jq)
    cat
    ;;

  launchctl)
    exit 0
    ;;

  lsof)
    exit 1
    ;;

  ps)
    echo "mockproc"
    ;;

  pkill)
    exit 0
    ;;

  sudo)
    shift
    "$@"
    ;;

  tee)
    cat >/dev/null
    ;;

  *)
    echo "Unhandled mock command: $cmd" >&2
    exit 1
    ;;
esac
MOCK

  chmod +x "$bin_dir/mockcmd"
  local cmd_name
  for cmd_name in uname vm_stat curl ollama podman jq launchctl lsof ps pkill sudo tee; do
    ln -sf mockcmd "$bin_dir/$cmd_name"
  done
}

run_test_help_output() {
  local out
  out="$($SUT --help)"
  assert_contains "$out" "OLLAMA_KEEP_ALIVE" || return 1
  assert_contains "$out" "OLLAMA_MAX_LOADED_MODELS" || return 1
  assert_contains "$out" "OLLAMA_NUM_PARALLEL" || return 1
  assert_contains "$out" "WEBUI_IMAGE" || return 1
}

run_test_unknown_command() {
  local out
  local code
  set +e
  out="$($SUT does-not-exist 2>&1)"
  code=$?
  set -e

  [[ $code -ne 0 ]] || return 1
  assert_contains "$out" "Unknown command: does-not-exist" || return 1
}

run_test_start_requires_install() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local home_dir="$tmpdir/home"
  local mock_bin="$tmpdir/bin"

  mkdir -p "$home_dir"
  create_mock_bin "$mock_bin"

  local out
  local code
  set +e
  out="$(HOME="$home_dir" PATH="$mock_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$SUT" start 2>&1)"
  code=$?
  set -e

  rm -rf "$tmpdir"

  [[ $code -ne 0 ]] || return 1
  assert_contains "$out" "install' first" || return 1
}

run_test_install_with_mocks() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local home_dir="$tmpdir/home"
  local mock_bin="$tmpdir/bin"

  mkdir -p "$home_dir"
  create_mock_bin "$mock_bin"

  local out
  local code
  set +e
  out="$(HOME="$home_dir" PATH="$mock_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$SUT" install 2>&1)"
  code=$?
  set -e

  if [[ $code -ne 0 ]]; then
    printf 'Install output:\n%s\n' "$out" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  [[ -f "$home_dir/.config/local-ai/config" ]] || return 1
  [[ -f "$home_dir/Library/LaunchAgents/ai.ollama.server.plist" ]] || return 1
  [[ -f "$home_dir/.local/bin/local-ai" ]] || return 1
  [[ -f "$home_dir/.zshrc" ]] || return 1

  assert_contains "$(cat "$home_dir/.config/local-ai/config")" 'WEBUI_IMAGE="ghcr.io/open-webui/open-webui:latest"' || return 1
  assert_contains "$(cat "$home_dir/.config/local-ai/config")" 'OLLAMA_KEEP_ALIVE="24h"' || return 1
  assert_contains "$(cat "$home_dir/.config/local-ai/config")" 'OLLAMA_MAX_LOADED_MODELS="1"' || return 1
  assert_contains "$(cat "$home_dir/.config/local-ai/config")" 'OLLAMA_NUM_PARALLEL="1"' || return 1
  assert_contains "$(cat "$home_dir/.config/local-ai/config")" 'RERANKING_MODEL=""' || return 1

  assert_contains "$(cat "$home_dir/Library/LaunchAgents/ai.ollama.server.plist")" 'OLLAMA_KEEP_ALIVE' || return 1
  assert_contains "$(cat "$home_dir/Library/LaunchAgents/ai.ollama.server.plist")" 'OLLAMA_MAX_LOADED_MODELS' || return 1
  assert_contains "$(cat "$home_dir/Library/LaunchAgents/ai.ollama.server.plist")" 'OLLAMA_NUM_PARALLEL' || return 1

  assert_contains "$(cat "$home_dir/.zshrc")" "alias ai='open http://localhost:3000'" || return 1
  assert_contains "$out" "Reranker disabled (strict-local default)." || return 1

  rm -rf "$tmpdir"
}

run_test_doctor_reranker_message() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local home_dir="$tmpdir/home"
  local mock_bin="$tmpdir/bin"

  mkdir -p "$home_dir"
  create_mock_bin "$mock_bin"

  local out
  out="$(HOME="$home_dir" PATH="$mock_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$SUT" doctor 2>&1)"

  assert_contains "$out" "Reranker disabled: no HuggingFace download during RAG." || return 1

  rm -rf "$tmpdir"
}

run_case() {
  local name="$1"
  local fn="$2"
  if "$fn"; then
    pass "$name"
  else
    fail "$name"
  fi
}

run_all_tests() {
  run_case "help output includes runtime vars" run_test_help_output
  run_case "unknown command fails" run_test_unknown_command
  run_case "start requires prior install" run_test_start_requires_install
  run_case "install works with mocks and writes hardened defaults" run_test_install_with_mocks
  run_case "doctor prints strict-local reranker note" run_test_doctor_reranker_message

  printf '\nSummary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

  if [[ $FAIL_COUNT -ne 0 ]]; then
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_all_tests
fi
