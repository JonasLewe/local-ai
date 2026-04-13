# Local AI Setup

Hassle-free, auditable local AI stack for macOS (Apple Silicon). Designed for regulated / air-gapped environments where cloud AI assistants are not an option.

**Stack:** Ollama (native) + Open WebUI (Podman) + launchd auto-start.

Target hardware: Apple Silicon with ≥32 GB RAM. Default model: Gemma 4 26B-A4B Q4_K_M.

## Quick Start

```bash
git clone <this-repo> local-ai-setup && cd local-ai-setup
./local-ai.sh install
```

After install, open the URL shown (default `http://localhost:3000`), create the admin account, and start chatting. The model is pre-loaded into RAM so the first response is instant.

## Prerequisites

- macOS 13+ on Apple Silicon
- Homebrew: `brew install ollama podman jq`
- ≥32 GB RAM (16 GB for the model + headroom)

## Commands

| Command                    | What it does                                                                                    |
| -------------------------- | ----------------------------------------------------------------------------------------------- |
| `./local-ai.sh install`    | First-time setup: download/import model, start Ollama, Podman, container, install launch agents |
| `./local-ai.sh start`      | Start all services (with safety check — refuses if not enough RAM)                              |
| `./local-ai.sh stop`       | Stop all services and free RAM + CPU                                                            |
| `./local-ai.sh update`     | Pull latest stable Open WebUI image, restart container                                          |
| `./local-ai.sh status`     | Health check all components, show available memory                                              |
| `./local-ai.sh doctor`     | Diagnose common problems (memory, ports, logs, connections)                                     |
| `./local-ai.sh logs`       | Tail all logs simultaneously                                                                    |
| `./local-ai.sh backup`     | Backup chats, settings & documents to `~/local-ai-backups/` (or custom dir)                     |
| `./local-ai.sh restore`    | Restore from a backup archive                                                                   |
| `./local-ai.sh uninstall`  | Remove launch agents and container. `--purge` also removes chat history volume                  |

After install, these shell aliases are available (open new terminal first):

| Alias        | What it does                          |
| ------------ | ------------------------------------- |
| `ai`         | Open chat UI in browser               |
| `ai-start`   | Start the stack (with RAM check)      |
| `ai-stop`    | Stop the stack, free resources        |
| `ai-status`  | Quick health check                    |
| `ai-logs`    | Tail container logs                   |
| `ai-update`  | Pull latest image + restart           |

## Configuration

All settings live in `~/.config/local-ai/config` (created automatically on first install). Edit the file and re-run `./local-ai.sh install` (or just `./local-ai.sh start`) to apply changes.

```bash
vi ~/.config/local-ai/config
./local-ai.sh start
```

| Variable                  | Default            | Purpose                                                |
| ------------------------- | ------------------ | ------------------------------------------------------ |
| `MODEL_ID`                | `gemma4-26b`       | Ollama model name (any from <https://ollama.com/library>) |
| `MODEL_SIZE_GB`           | `16`               | Estimated model size — used by RAM safety check        |
| `MODEL_CONTEXT_LENGTH`    | `32768`            | Context window in tokens (4K default in Ollama is too small) |
| `MODEL_GGUF_PATH`         | (empty)            | Optional: import existing GGUF instead of pulling      |
| `WEBUI_HOSTNAME`          | `localhost`        | Custom hostname (e.g. `ai.local`)                      |
| `WEBUI_PORT`              | `3000`             | Open WebUI port (use `80` with custom hostname for clean URL) |
| `OLLAMA_PORT`             | `11434`            | Ollama API port                                        |
| `OLLAMA_FLASH_ATTENTION`  | `0`                | Set `1` for faster inference + smaller KV cache        |
| `OLLAMA_KV_CACHE_TYPE`    | `f16`              | Set `q8_0` to halve KV cache RAM (recommended)         |
| `PODMAN_CPUS`             | `6`                | Podman VM CPU count                                    |
| `PODMAN_MEMORY`           | `4096`             | Podman VM memory in MB                                 |

### Recommended settings for Gemma 4 on M1 Max 32 GB

```bash
MODEL_ID="gemma4-26b"
MODEL_CONTEXT_LENGTH="65536"
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KV_CACHE_TYPE="q8_0"
```

This gets you a 64K context window with the model fitting comfortably in RAM alongside macOS and Open WebUI.

### Importing existing GGUF files (no re-download)

If you already have GGUF model files (e.g. from LM Studio):

```bash
MODEL_GGUF_PATH="/path/to/model.gguf"
```

Ollama will import the file in place — no extra download.

### Custom hostname (e.g. `http://ai.local`)

```bash
WEBUI_HOSTNAME="ai.local"
WEBUI_PORT="80"
```

The script adds the hostname to `/etc/hosts` (asks for sudo once).

## Safety: How the script protects your system

Loading a 16 GB model on a 32 GB system is tight. The script enforces two hard checks before loading:

1. **`preflight_memory_check`** — reads `vm_stat`, refuses to start if `MODEL_SIZE_GB + 4 GB buffer` is not free.
2. **`check_no_competing_servers`** — refuses to start Ollama if LM Studio (or any other model server) still has models loaded in RAM.

If a check fails, the script **exits hard with a clear error message** rather than crashing the system.

## Architecture

```
Login
  └─ launchd (RunAtLoad)
       ├─ ai.ollama.server     → ollama serve (native, Apple Silicon GPU)
       ├─ io.podman.machine    → podman machine start
       └─ ai.openwebui         → waits for machine, starts container
                                    └─ host.containers.internal:11434 → Ollama
```

Open WebUI talks to Ollama via Ollama's native API (no OpenAI-compat bridge), which avoids issues with reasoning models like Gemma 4.

## Recommended Model Params (Gemma 4)

Set in Open WebUI → Admin Panel → Settings → Models → `gemma4-26b` → Advanced Params:

- Temperature: 1.0
- Top-P: 0.95
- Top-K: 64
- Repeat Penalty: 1.0 (disabled)
- Context Length: matches `MODEL_CONTEXT_LENGTH` from config

These are Google's official defaults. Do **not** apply Llama-style sampling.

## Troubleshooting

**First line of defense:** `./local-ai.sh doctor`

| Symptom                                       | Fix                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------- |
| `INSUFFICIENT MEMORY` on start                | Close some apps, then retry. The script protects you from a crash.  |
| `LM Studio still has models loaded`           | `~/.lmstudio/bin/lms unload --all && lms server stop`               |
| Container running but HTTP 502                | Ollama not up — check `tail ~/.local/share/local-ai/logs/ollama.err.log` |
| Port 3000 already in use                      | Change `WEBUI_PORT` in config, re-run `install`                     |
| Podman machine stuck starting                 | `podman machine stop && podman machine start`                       |
| After macOS update nothing starts             | `launchctl load ~/Library/LaunchAgents/ai.*.plist`                  |
| Ollama doesn't recognize model architecture   | Update Ollama: `brew upgrade ollama`                                |

## Migration from v1.x (LM Studio) to v2.x (Ollama)

If you ran an older version with LM Studio:

1. Stop the old stack: `local-ai stop`
2. Unload LM Studio: `~/.lmstudio/bin/lms unload --all && ~/.lmstudio/bin/lms server stop`
3. Disable LM Studio auto-start: `launchctl unload ~/Library/LaunchAgents/ai.lmstudio.server.plist`
4. Install Ollama: `brew install ollama`
5. Update your config — see `~/.config/local-ai/config`. Set `MODEL_GGUF_PATH` to your existing LM Studio GGUF file to avoid re-downloading.
6. Re-run install: `./local-ai.sh install`

LM Studio app and downloaded models are not touched — you can keep or remove them later.

## Security Notes (regulated environments)

- Ollama binds to `127.0.0.1` only (localhost) via `OLLAMA_HOST` env in launchd plist
- WebUI auth is enabled by default (`WEBUI_AUTH=true`)
- OpenAI API integration disabled (`ENABLE_OPENAI_API=false`) — Ollama-only
- Model files live under `~/.ollama/models/`, WebUI data in Podman volume `open-webui`
- Logs persist in `~/.local/share/local-ai/logs/` (survive reboots for audit trail)
- Regular backups: `./local-ai.sh backup` — stores chats, settings, and uploaded documents
- For full air-gap audit: pair with outbound firewall (Little Snitch / LuLu) blocking Ollama from any non-localhost destination

## Contributing

PRs welcome. Keep changes idempotent — the script must survive being re-run. Test with:

```bash
./local-ai.sh uninstall --purge
./local-ai.sh install
./local-ai.sh status
```

## Changelog

- **2.0.0** — Switch from LM Studio to Ollama (native API, better Gemma 4 support); add safety checks (RAM preflight, competing-server check); add `MODEL_CONTEXT_LENGTH`, `MODEL_GGUF_PATH`, `OLLAMA_FLASH_ATTENTION`, `OLLAMA_KV_CACHE_TYPE`
- **1.1.0** — Stable image, auto model download, persistent logs, backup/restore, custom hostname, optimized resources
- **1.0.0** — Initial release: LM Studio + Open WebUI + Podman + launchd
