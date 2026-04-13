# Local AI Setup

Hassle-free, auditable local AI stack for macOS (Apple Silicon). Designed for regulated / air-gapped environments where cloud AI assistants are not an option.

**Stack:** LM Studio (headless) + Open WebUI (Podman, stable) + launchd auto-start.

Target hardware: Apple Silicon with ≥32 GB RAM. Default model: Gemma 4 26B-A4B Q4_K_M (auto-downloaded on install).

## Quick Start

```bash
git clone <this-repo> local-ai-setup && cd local-ai-setup
./local-ai.sh install
```

After install, open http://localhost:3000, create the admin account, and select the model in a new chat. First response triggers JIT model load (~30 s once).

## Prerequisites

- macOS 13+ on Apple Silicon
- [LM Studio](https://lmstudio.ai) installed in `/Applications/`
- Homebrew: `brew install podman jq`
- At least one Gemma 4 model downloaded via LM Studio (recommended: `google/gemma-4-26b-a4b` Q4_K_M)

## Commands

| Command                    | What it does                                                                                          |
| -------------------------- | ----------------------------------------------------------------------------------------------------- |
| `./local-ai.sh install`    | First-time setup: download model, configure LM Studio, start Podman, create container, launch agents  |
| `./local-ai.sh start`      | Start all services (LM Studio, Podman, Open WebUI)                                                    |
| `./local-ai.sh stop`       | Stop all services and free RAM + CPU                                                                  |
| `./local-ai.sh update`     | Pull latest stable Open WebUI image, restart container                                                |
| `./local-ai.sh status`     | Health check all components                                                                           |
| `./local-ai.sh doctor`     | Diagnose common problems (ports, logs, connections)                                                   |
| `./local-ai.sh logs`       | Tail all logs simultaneously                                                                          |
| `./local-ai.sh backup`     | Backup chats, settings & documents to `~/local-ai-backups/` (or custom dir)                           |
| `./local-ai.sh restore`    | Restore from a backup archive                                                                         |
| `./local-ai.sh uninstall`  | Remove launch agents and container. `--purge` also removes chat history volume                        |

After install, these shell aliases are available (open new terminal first):

| Alias        | What it does                    |
| ------------ | ------------------------------- |
| `ai`         | Open chat UI in browser         |
| `ai-start`   | Start the stack                 |
| `ai-stop`    | Stop the stack, free resources  |
| `ai-status`  | Quick health check              |
| `ai-logs`    | Tail container logs             |
| `ai-update`  | Pull latest image + restart     |

## Configuration

All settings live in `~/.config/local-ai/config` (created automatically on first install). Edit the file and re-run `./local-ai.sh install` to apply changes.

```bash
# Switch to a different model:
vi ~/.config/local-ai/config
# Change MODEL_ID="google/gemma-4-26b-a4b" to e.g. MODEL_ID="meta-llama/llama-3.1-8b-instruct"
./local-ai.sh install
```

You can also override per-run via env vars:

```bash
WEBUI_PORT=8080 ./local-ai.sh install
```

| Variable        | Default                    | Purpose                         |
| --------------- | -------------------------- | ------------------------------- |
| `LMS_PORT`      | 1234                       | LM Studio OpenAI-compatible API |
| `WEBUI_PORT`    | 3000                       | Open WebUI browser port         |
| `MODEL_ID`      | google/gemma-4-26b-a4b     | Model to auto-download          |
| `PODMAN_CPUS`   | 6                          | VM CPU count                    |
| `PODMAN_MEMORY` | 4096                       | VM memory (MB)                  |

## Recommended LM Studio Model Params (Gemma 4)

Set once in Open WebUI → Admin Panel → Models → `google/gemma-4-26b-a4b` → Advanced Params:

- Temperature: 1.0
- Top-P: 0.95
- Top-K: 64
- Repeat Penalty: 1.0 (disabled)
- Context Length: 131072 (Gemma 4 maximum — reduce to 65536 if you experience slowness)

These are Google's official defaults. Do **not** apply Llama-style sampling.

## Architecture

```
Login
  └─ launchd (RunAtLoad)
       ├─ ai.lmstudio.server   → lms server start :1234
       ├─ io.podman.machine    → podman machine start
       └─ ai.openwebui         → waits for machine, starts container
                                    └─ host.docker.internal:1234 → LM Studio
```

Open WebUI JIT-loads the model on first chat request. No model is held in RAM until used.

## Troubleshooting

**First line of defense:** `./local-ai.sh doctor`

| Symptom                                  | Fix                                                     |
| ---------------------------------------- | ------------------------------------------------------- |
| `lms: command not found` after bootstrap | Open LM Studio.app once, re-run install                 |
| Container running but HTTP 502           | LM Studio server not up — check `tail /tmp/lms.err.log` |
| Port 3000 already in use                 | `WEBUI_PORT=3001 ./local-ai.sh install`                 |
| Podman machine stuck starting            | `podman machine stop && podman machine start`           |
| After macOS update nothing starts        | `launchctl load ~/Library/LaunchAgents/ai.*.plist`      |

## Security Notes (regulated environments)

- LM Studio server binds to `127.0.0.1` only (localhost)
- WebUI auth is enabled by default (`WEBUI_AUTH=true`)
- No telemetry — disable it in LM Studio settings manually on first launch
- Model files live under `~/.lmstudio/models/`, WebUI data in Podman volume `open-webui`
- Logs persist in `~/.local/share/local-ai/logs/` (survive reboots for audit trail)
- Regular backups: `./local-ai.sh backup` — stores chats, settings, and uploaded documents
- For full audit: pair with outbound firewall (Little Snitch / LuLu) blocking the LM Studio helper process

## Contributing

PRs welcome. Keep changes idempotent — the script must survive being re-run. Test with:

```bash
./local-ai.sh uninstall --purge
./local-ai.sh install
./local-ai.sh status
```

## Changelog

- **1.1.0** — Stable image, auto model download, persistent logs, backup/restore, optimized resources
- **1.0.0** — Initial release: LM Studio + Open WebUI + Podman + launchd
