# Proxmox Paperless AI

One-liner installer for a full AI-powered document management stack.

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/fahmykhattab/proxmox-paperless-ai/main/paperless-ai-stack.sh)"
```

## Install Modes

The script auto-detects your environment:

### 🖥️ Proxmox VE Host
Creates a dedicated **LXC container** with Docker, then deploys the full stack inside it. Clean separation from your hypervisor.

- Auto-creates privileged LXC with Docker support
- Configurable CT ID, hostname, CPU, RAM, disk, network
- Downloads Debian 12 template if needed
- Installs Docker inside the LXC automatically
- Detects PVE host Ollama for AI integration

### 🐧 Standalone (Any Linux)
Runs directly on any machine with Docker — bare metal, VM, existing LXC, VPS.

- Works on Debian, Ubuntu, or any Docker-capable distro
- Auto-detects Docker and Docker Compose

## What It Deploys

| Service | Port | Description |
|---------|------|-------------|
| **Paperless-ngx** | 8000 | Document Management System with OCR |
| **Paperless-GPT** | 8081 | LLM-powered OCR enhancement & auto-tagging |
| **Paperless-AI** | 3000 | Auto classification & RAG chat |
| **PostgreSQL 16** | — | Database |
| **Redis 7** | — | Message broker |

## Features

- 🔧 **Interactive setup** — prompts for IP, admin creds, timezone, OCR languages
- 🤖 **Ollama auto-detection** — finds local Ollama instance and lists available models
- 🔑 **Auto API token** — generates and wires the Paperless API token automatically
- ✅ **Validation** — Docker Compose syntax check before deployment
- 📋 **Health checks** — verifies all 5 services are running before finishing
- 🔄 **Retry logic** — retries API token generation up to 3 times
- 🧹 **Cleanup on failure** — stops containers if installation fails
- 🌍 **Multi-language OCR** — supports any Tesseract language (eng, deu, fra, ara, etc.)
- 📁 **Drop folder** — place files in `consume/` for automatic ingestion
- 🔒 **Secure credentials** — saved with restricted file permissions

## Requirements

**Proxmox mode:**
- Proxmox VE 7+ with a Debian/Ubuntu template available

**Standalone mode:**
- Docker & Docker Compose v2+

**Optional:**
- [Ollama](https://ollama.ai) for local AI inference

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Proxmox VE Host                                        │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │  LXC Container (paperless)                       │   │
│  │                                                  │   │
│  │  ┌─────────────┐  ┌──────────────┐              │   │
│  │  │  Upload PDF  │──│ Paperless-ngx │──┐          │   │
│  │  │  or Image    │  │   (OCR)       │  │          │   │
│  │  └─────────────┘  └──────────────┘  │          │   │
│  │                                      ▼          │   │
│  │                   ┌──────────────┐ ┌─────────┐  │   │
│  │                   │ Paperless-GPT │ │Postgres │  │   │
│  │                   │ (AI Tagging)  │ │  Redis  │  │   │
│  │                   └──────┬───────┘ └─────────┘  │   │
│  │                          │                       │   │
│  │                   ┌──────▼───────┐              │   │
│  │                   │ Paperless-AI  │              │   │
│  │                   │(Classify+RAG) │              │   │
│  │                   └──────────────┘              │   │
│  └──────────────────────┬───────────────────────────┘   │
│                         │                               │
│  ┌──────────────────────▼──────────────────────────┐   │
│  │  Ollama (host)         :11434                    │   │
│  │  qwen3, llama3, etc.                             │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Post-Install

1. Open Paperless-ngx at `http://YOUR_IP:8000` and log in
2. Upload a document or drop it in the `consume/` folder
3. Tag documents with `paperless-gpt` to trigger AI OCR & tagging
4. Configure Paperless-AI at `http://YOUR_IP:3000` (first-run web setup)

## Configuration

All config lives in `docker-compose.yaml` at the install directory (default: `/opt/paperless/`).

Credentials are saved to `.credentials` in the install directory.

### Supported OCR Languages

Combine with `+` — examples:
- `eng` — English only
- `deu+eng` — German + English
- `deu+eng+ara` — German + English + Arabic
- `fra+eng` — French + English

Full list: [Tesseract languages](https://tesseract-ocr.github.io/tessdoc/Data-Files-in-different-versions.html)

### Management Commands

```bash
# If installed in LXC, enter it first:
pct enter <CT_ID>

# Then manage the stack:
cd /opt/paperless
docker compose logs -f          # View logs
docker compose restart           # Restart all
docker compose down              # Stop all
docker compose up -d             # Start all
docker compose pull && docker compose up -d   # Update images
```

## License

MIT — see [LICENSE](LICENSE)

## Author

Dr. Fahmy Khattab — [GitHub](https://github.com/fahmykhattab)
