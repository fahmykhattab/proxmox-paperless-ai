#!/usr/bin/env bash
# =============================================================================
# Paperless-ngx + Paperless-GPT + Paperless-AI — One-Line Installer
# =============================================================================
# Deploy a full AI-powered document management stack with Docker Compose.
#
# Two modes:
#   1. PROXMOX MODE — Run on PVE host: creates a dedicated LXC, installs
#      Docker inside it, and deploys the full stack automatically.
#   2. STANDALONE MODE — Run on any Linux machine with Docker already
#      installed (bare metal, VM, existing LXC, VPS, etc.)
#
# Usage (Proxmox host):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/fahmykhattab/proxmox-paperless-ai/main/paperless-ai-stack.sh)"
#
# Usage (any machine with Docker):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/fahmykhattab/proxmox-paperless-ai/main/paperless-ai-stack.sh)"
#
# What it deploys:
#   - Paperless-ngx    (Document Management)    → port 8000
#   - Paperless-GPT    (LLM OCR & Tagging)      → port 8081
#   - Paperless-AI     (Auto Classification)     → port 3000
#   - PostgreSQL 16    (Database)
#   - Redis 7          (Message Broker)
#
# Requirements:
#   Proxmox mode: Proxmox VE 7+ with a Debian/Ubuntu template
#   Standalone:   Docker & Docker Compose v2+
#   Optional:     Ollama for local LLM inference
#
# Author: Dr. Fahmy Khattab / Kemo AI
# License: MIT
# =============================================================================

set -euo pipefail

# ─── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
ok()      { echo -e "${GREEN}✔${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "${RED}✖${NC}  $*"; }
header()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}\n"; }

prompt_var() {
    local varname="$1" prompt="$2" default="$3"
    local input
    read -rp "$(echo -e "${CYAN}?${NC}  ${prompt} [${default}]: ")" input
    eval "${varname}=\"${input:-${default}}\""
}

cleanup() {
    if [ "${INSTALL_FAILED:-false}" = true ] && [ -n "${COMPOSE_CMD:-}" ] && [ -d "${INSTALL_DIR:-}" ]; then
        warn "Installation failed. Cleaning up containers..."
        cd "$INSTALL_DIR" && $COMPOSE_CMD down 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Detect Environment ──────────────────────────────────────────────────────
header "Paperless AI Stack Installer"
echo -e "  ${BOLD}Paperless-ngx${NC} + ${BOLD}Paperless-GPT${NC} + ${BOLD}Paperless-AI${NC}"
echo -e "  AI-powered Document Management System"
echo ""

IS_PROXMOX=false
if command -v pveversion &>/dev/null; then
    IS_PROXMOX=true
    PVE_VERSION=$(pveversion --verbose 2>/dev/null | grep "^pve-manager" | awk '{print $2}' || pveversion 2>/dev/null)
    ok "Proxmox VE detected: ${PVE_VERSION}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Create a new LXC container (recommended)"
    echo -e "  ${BOLD}2)${NC} Install directly on this host"
    echo ""
    prompt_var INSTALL_MODE "Install mode" "1"
else
    INSTALL_MODE="2"
fi

# =============================================================================
# PROXMOX LXC MODE
# =============================================================================
if [ "$INSTALL_MODE" = "1" ] && [ "$IS_PROXMOX" = true ]; then
    header "LXC Container Setup"

    # ─── Find next available CT ID ────────────────────────────────────────
    NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
    prompt_var CT_ID "Container ID" "$NEXT_ID"

    # Check if ID is already in use
    if pct status "$CT_ID" &>/dev/null; then
        err "CT $CT_ID already exists!"
        exit 1
    fi

    prompt_var CT_HOSTNAME "Hostname" "paperless"

    # ─── Resources ────────────────────────────────────────────────────────
    prompt_var CT_CORES "CPU cores" "2"
    prompt_var CT_MEMORY "Memory (MB)" "4096"
    prompt_var CT_DISK "Disk size (GB)" "20"
    prompt_var CT_SWAP "Swap (MB)" "512"

    # ─── Storage ──────────────────────────────────────────────────────────
    STORAGES=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
    if [ -z "$STORAGES" ]; then
        STORAGES="local"
    fi
    info "Available storage: ${STORAGES}"
    prompt_var CT_STORAGE "Storage for rootfs" "local"

    # ─── Template ─────────────────────────────────────────────────────────
    info "Available templates:"
    TEMPLATES=$(pveam list "$CT_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}')
    if [ -z "$TEMPLATES" ]; then
        info "No templates found. Downloading Debian 12..."
        pveam download "$CT_STORAGE" debian-12-standard_12.12-1_amd64.tar.zst 2>/dev/null || \
        pveam download "$CT_STORAGE" debian-12-standard_12.7-1_amd64.tar.zst 2>/dev/null || {
            err "Failed to download template. Please download manually:"
            info "  pveam update && pveam download $CT_STORAGE debian-12-standard_12.12-1_amd64.tar.zst"
            exit 1
        }
        TEMPLATES=$(pveam list "$CT_STORAGE" 2>/dev/null | awk 'NR>1 {print $1}')
    fi

    # Default to latest Debian 12
    DEFAULT_TPL=$(echo "$TEMPLATES" | grep -i "debian-12" | sort -V | tail -1)
    [ -z "$DEFAULT_TPL" ] && DEFAULT_TPL=$(echo "$TEMPLATES" | head -1)

    echo "$TEMPLATES" | while read -r t; do echo "    - $t"; done
    echo ""
    prompt_var CT_TEMPLATE "Template" "$DEFAULT_TPL"

    # ─── Network ──────────────────────────────────────────────────────────
    BRIDGES=$(ip link show type bridge 2>/dev/null | grep -oP '^\d+: \K[^:]+' || echo "vmbr0")
    DEFAULT_BRIDGE=$(echo "$BRIDGES" | head -1)
    prompt_var CT_BRIDGE "Network bridge" "$DEFAULT_BRIDGE"
    prompt_var CT_IP "IP config (dhcp or IP/CIDR)" "dhcp"

    if [ "$CT_IP" != "dhcp" ]; then
        # Need gateway for static IP
        DEFAULT_GW=$(ip route | grep default | awk '{print $3}' | head -1)
        prompt_var CT_GW "Gateway" "$DEFAULT_GW"
        NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}"
    else
        NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
    fi

    # ─── Password ─────────────────────────────────────────────────────────
    CT_PASS=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
    info "Generated root password: ${CT_PASS}"
    info "(saved to credentials file after install)"

    # ─── Summary ──────────────────────────────────────────────────────────
    header "LXC Summary"
    echo -e "  ${BOLD}CT ID:${NC}       $CT_ID"
    echo -e "  ${BOLD}Hostname:${NC}    $CT_HOSTNAME"
    echo -e "  ${BOLD}Template:${NC}    $CT_TEMPLATE"
    echo -e "  ${BOLD}CPU:${NC}         $CT_CORES cores"
    echo -e "  ${BOLD}Memory:${NC}      ${CT_MEMORY}MB + ${CT_SWAP}MB swap"
    echo -e "  ${BOLD}Disk:${NC}        ${CT_DISK}GB on ${CT_STORAGE}"
    echo -e "  ${BOLD}Network:${NC}     $NET_CONFIG"
    echo ""

    read -rp "$(echo -e "${CYAN}?${NC}  Create LXC and install Paperless AI Stack? [Y/n]: ")" CONFIRM
    if [[ "${CONFIRM,,}" =~ ^(n|no)$ ]]; then
        warn "Installation cancelled."
        exit 0
    fi

    # ─── Create LXC ──────────────────────────────────────────────────────
    header "Creating LXC Container"
    info "Creating CT ${CT_ID} (${CT_HOSTNAME})..."

    pct create "$CT_ID" "$CT_TEMPLATE" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_DISK}" \
        --net0 "$NET_CONFIG" \
        --ostype debian \
        --password "$CT_PASS" \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --unprivileged 0 \
        --start 0

    ok "CT ${CT_ID} created"

    # ─── Configure for Docker ─────────────────────────────────────────────
    info "Configuring LXC for Docker support..."

    # Add required LXC config for Docker-in-LXC
    {
        echo "lxc.apparmor.profile: unconfined"
        echo "lxc.cgroup2.devices.allow: a"
        echo "lxc.cap.drop: "
        echo "lxc.mount.auto: proc:rw sys:rw"
    } >> "/etc/pve/lxc/${CT_ID}.conf"

    ok "Docker support configured"

    # ─── Start LXC ────────────────────────────────────────────────────────
    info "Starting CT ${CT_ID}..."
    pct start "$CT_ID"
    sleep 5

    # Wait for network
    info "Waiting for network..."
    RETRIES=0
    while [ $RETRIES -lt 30 ]; do
        if pct exec "$CT_ID" -- ping -c1 -W2 8.8.8.8 &>/dev/null; then
            break
        fi
        RETRIES=$((RETRIES + 1))
        sleep 2
    done

    if [ $RETRIES -ge 30 ]; then
        err "CT ${CT_ID} has no network connectivity"
        exit 1
    fi

    # Get CT IP
    CT_ACTUAL_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
    ok "CT ${CT_ID} is online at ${CT_ACTUAL_IP}"

    # ─── Install Docker inside LXC ────────────────────────────────────────
    header "Installing Docker in LXC"
    info "Updating packages..."
    pct exec "$CT_ID" -- bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates gnupg >/dev/null 2>&1"
    ok "Base packages installed"

    info "Installing Docker (this takes 1-2 minutes)..."
    pct exec "$CT_ID" -- bash -c "curl -fsSL https://get.docker.com | sh" >/dev/null 2>&1
    pct exec "$CT_ID" -- systemctl enable --now docker >/dev/null 2>&1
    ok "Docker installed"

    # Verify Docker works
    if pct exec "$CT_ID" -- docker run --rm hello-world &>/dev/null; then
        ok "Docker is working inside CT ${CT_ID}"
    else
        warn "Docker test failed — containers may still work"
    fi

    # ─── Now run the Paperless install inside the LXC ─────────────────────
    # We pass the configuration as environment variables and run the
    # standalone installer part inside the container
    header "Installing Paperless AI Stack in CT ${CT_ID}"

    # Detect PVE host IP (for Ollama access from inside LXC)
    PVE_HOST_IP=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    [ -z "$PVE_HOST_IP" ] && PVE_HOST_IP=$(hostname -I | awk '{print $1}')

    # Download the script inside the LXC and run it
    # We re-download to ensure it runs natively inside the container
    info "Launching Paperless installer inside the container..."
    info "The installer will ask you configuration questions now."
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Entering CT ${CT_ID} — configure the Paperless stack below${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Pass PVE host IP hint as environment variable
    pct exec "$CT_ID" -- bash -c "
        export PAPERLESS_PVE_HOST_IP='${PVE_HOST_IP}'
        bash <(curl -fsSL https://raw.githubusercontent.com/fahmykhattab/proxmox-paperless-ai/main/paperless-ai-stack.sh)
    "

    STACK_EXIT=$?

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Back on Proxmox host${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    if [ $STACK_EXIT -eq 0 ]; then
        header "Proxmox LXC Installation Complete!"
        echo ""
        echo -e "  ${BOLD}${GREEN}🎉 Paperless AI Stack is running in CT ${CT_ID}!${NC}"
        echo ""
        echo -e "  ${BOLD}Container:${NC}"
        echo -e "    CT ID:        ${CT_ID}"
        echo -e "    Hostname:     ${CT_HOSTNAME}"
        echo -e "    IP:           ${CT_ACTUAL_IP}"
        echo -e "    Root pass:    ${CT_PASS}"
        echo ""
        echo -e "  ${BOLD}Access:${NC}"
        echo -e "    📄 Paperless-ngx   → ${CYAN}http://${CT_ACTUAL_IP}:8000${NC}"
        echo -e "    🤖 Paperless-GPT   → ${CYAN}http://${CT_ACTUAL_IP}:8081${NC}"
        echo -e "    🧠 Paperless-AI    → ${CYAN}http://${CT_ACTUAL_IP}:3000${NC}"
        echo ""
        echo -e "  ${BOLD}Management:${NC}"
        echo -e "    pct enter ${CT_ID}              # Enter container shell"
        echo -e "    pct exec ${CT_ID} -- docker compose -f /opt/paperless/docker-compose.yaml logs -f"
        echo ""

        # Save LXC credentials
        LXC_CREDS="/etc/pve/local/paperless-ct${CT_ID}.creds"
        cat > "$LXC_CREDS" << LXCCREDSEOF
# Paperless AI Stack — LXC ${CT_ID}
# Generated: $(date -Iseconds)
CT ID:        ${CT_ID}
Hostname:     ${CT_HOSTNAME}
IP:           ${CT_ACTUAL_IP}
Root pass:    ${CT_PASS}
Paperless:    http://${CT_ACTUAL_IP}:8000
GPT:          http://${CT_ACTUAL_IP}:8081
AI:           http://${CT_ACTUAL_IP}:3000
LXCCREDSEOF
        chmod 600 "$LXC_CREDS"
        ok "LXC credentials saved to ${LXC_CREDS}"
    else
        err "Installation inside CT ${CT_ID} failed (exit code: ${STACK_EXIT})"
        warn "Container is still running — you can debug with: pct enter ${CT_ID}"
    fi

    exit $STACK_EXIT
fi

# =============================================================================
# STANDALONE MODE (any machine with Docker)
# =============================================================================

# ─── Pre-flight Checks ───────────────────────────────────────────────────────

# Check root
if [ "$(id -u)" -ne 0 ]; then
    warn "Running without root — some operations may fail"
fi

# Check Docker
if ! command -v docker &>/dev/null; then
    err "Docker is not installed!"
    echo ""
    info "Install Docker first:"
    echo "    curl -fsSL https://get.docker.com | sh"
    exit 1
fi
ok "Docker found: $(docker --version | head -1)"

# Check Docker is running
if ! docker info &>/dev/null; then
    err "Docker daemon is not running!"
    info "Start it with: systemctl start docker"
    exit 1
fi
ok "Docker daemon is running"

# Check Docker Compose
if docker compose version &>/dev/null; then
    ok "Docker Compose found: $(docker compose version --short 2>/dev/null || echo 'v2+')"
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    ok "Docker Compose found (standalone)"
    COMPOSE_CMD="docker-compose"
else
    err "Docker Compose is not installed!"
    exit 1
fi

# Check curl (needed for health checks and Ollama detection)
if ! command -v curl &>/dev/null; then
    info "Installing curl..."
    if apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1; then
        ok "curl installed"
    else
        err "curl is required but could not be installed"
        exit 1
    fi
fi

# ─── Configuration ────────────────────────────────────────────────────────────
header "Configuration"

# Install directory
prompt_var INSTALL_DIR "Install directory" "/opt/paperless"

# Check for existing installation
if [ -f "$INSTALL_DIR/docker-compose.yaml" ]; then
    warn "Existing installation found at $INSTALL_DIR"
    read -rp "$(echo -e "${CYAN}?${NC}  Overwrite config? Data volumes are preserved. [y/N]: ")" OVERWRITE
    if [[ ! "${OVERWRITE,,}" =~ ^(y|yes)$ ]]; then
        warn "Installation cancelled."
        exit 0
    fi
fi

# Detect host IP
DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$DEFAULT_IP" ] && DEFAULT_IP="localhost"
prompt_var HOST_IP "Host IP address" "$DEFAULT_IP"

# Admin credentials
prompt_var ADMIN_USER "Paperless admin username" "admin"

# Password prompt
echo -e "${YELLOW}⚠${NC}  Change the default password if this is not a test setup!"
prompt_var ADMIN_PASS "Paperless admin password" "admin"

# Timezone
DETECTED_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")
prompt_var TIMEZONE "Timezone" "$DETECTED_TZ"

# OCR Languages
echo ""
info "Common OCR languages: eng (English), deu (German), fra (French),"
info "  spa (Spanish), ita (Italian), ara (Arabic), chi-sim (Chinese)"
info "Combine with +, e.g.: deu+eng+ara"
prompt_var OCR_LANGS "OCR languages (tesseract format)" "eng"

# Secret key
SECRET_KEY=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)

# ─── Ollama Configuration ────────────────────────────────────────────────────
header "AI / LLM Configuration"
echo ""
info "Paperless-GPT uses an LLM for OCR enhancement and document tagging."
info "Ollama is recommended for local/self-hosted AI inference."
echo ""

prompt_var USE_OLLAMA "Use Ollama for AI? (y/n)" "y"

OLLAMA_DOCKER_URL=""
LLM_MODEL=""
VISION_MODEL=""
LLM_LANGUAGE="English"
OLLAMA_URL=""

if [[ "${USE_OLLAMA,,}" =~ ^(y|yes)$ ]]; then
    # Check for PVE host IP hint (set when running inside LXC from Proxmox mode)
    PVE_HINT="${PAPERLESS_PVE_HOST_IP:-}"

    # Auto-detect Ollama
    OLLAMA_DETECTED=""
    CANDIDATES=("http://localhost:11434" "http://127.0.0.1:11434" "http://${HOST_IP}:11434")
    # If we have a PVE host hint, try that too
    if [ -n "$PVE_HINT" ] && [ "$PVE_HINT" != "$HOST_IP" ]; then
        CANDIDATES+=("http://${PVE_HINT}:11434")
    fi

    for candidate in "${CANDIDATES[@]}"; do
        if curl -sS --max-time 3 "$candidate/api/tags" &>/dev/null; then
            OLLAMA_DETECTED="$candidate"
            break
        fi
    done

    if [ -n "$OLLAMA_DETECTED" ]; then
        ok "Ollama detected at $OLLAMA_DETECTED"
        prompt_var OLLAMA_URL "Ollama URL" "$OLLAMA_DETECTED"
    else
        DEFAULT_OLLAMA_URL="http://${PVE_HINT:-${HOST_IP}}:11434"
        warn "Ollama not detected on common ports"
        info "If Ollama is on the Proxmox host, use the host IP"
        prompt_var OLLAMA_URL "Ollama URL" "$DEFAULT_OLLAMA_URL"
    fi

    # Docker gateway for containers to reach host network
    DOCKER_GW=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "172.17.0.1")

    # Determine the Ollama URL for Docker containers
    # If Ollama is on localhost/127.0.0.1, containers need the Docker gateway
    OLLAMA_HOST_PART=$(echo "$OLLAMA_URL" | sed -E 's|https?://||;s|:[0-9]+$||')
    if [ "$OLLAMA_HOST_PART" = "localhost" ] || [ "$OLLAMA_HOST_PART" = "127.0.0.1" ]; then
        OLLAMA_DOCKER_URL="http://${DOCKER_GW}:11434"
        info "Containers will reach Ollama via Docker gateway: $OLLAMA_DOCKER_URL"
    else
        # Ollama is on a remote/LAN IP, containers can use it directly
        OLLAMA_DOCKER_URL="$OLLAMA_URL"
    fi

    # List available models
    echo ""
    info "Fetching available Ollama models..."
    MODELS=""
    if command -v python3 &>/dev/null; then
        MODELS=$(curl -sS --max-time 5 "${OLLAMA_URL}/api/tags" 2>/dev/null | python3 -c "
import sys,json
try:
    data=json.load(sys.stdin)
    for m in data.get('models',[]):
        print(m['name'])
except: pass
" 2>/dev/null || true)
    fi

    if [ -n "$MODELS" ]; then
        ok "Available models:"
        echo "$MODELS" | while read -r m; do echo "      - $m"; done
        echo ""
        DEFAULT_MODEL=$(echo "$MODELS" | head -1)
    else
        warn "Could not fetch models (Ollama may be offline or python3 not available)"
        DEFAULT_MODEL="llama3:8b"
    fi
    prompt_var LLM_MODEL "LLM model for tagging & OCR" "$DEFAULT_MODEL"

    # Vision model (can be same or different)
    prompt_var VISION_MODEL "Vision model for OCR (or same as LLM)" "$LLM_MODEL"
else
    warn "Skipping Ollama — Paperless-GPT will need manual LLM configuration"
    warn "Edit docker-compose.yaml later to add your LLM provider settings"
fi

# Language for LLM responses
prompt_var LLM_LANGUAGE "LLM response language" "English"

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Installation Summary"
echo -e "  ${BOLD}Directory:${NC}     $INSTALL_DIR"
echo -e "  ${BOLD}Host IP:${NC}       $HOST_IP"
echo -e "  ${BOLD}Admin:${NC}         $ADMIN_USER / $ADMIN_PASS"
echo -e "  ${BOLD}Timezone:${NC}      $TIMEZONE"
echo -e "  ${BOLD}OCR Langs:${NC}     $OCR_LANGS"
if [[ "${USE_OLLAMA,,}" =~ ^(y|yes)$ ]]; then
    echo -e "  ${BOLD}Ollama URL:${NC}    ${OLLAMA_URL}"
    echo -e "  ${BOLD}Docker URL:${NC}    $OLLAMA_DOCKER_URL"
    echo -e "  ${BOLD}LLM Model:${NC}    $LLM_MODEL"
    echo -e "  ${BOLD}Vision Model:${NC} $VISION_MODEL"
fi
echo -e "  ${BOLD}LLM Language:${NC}  $LLM_LANGUAGE"
echo ""
echo -e "  ${BOLD}Ports:${NC}"
echo -e "    Paperless-ngx   → http://${HOST_IP}:8000"
echo -e "    Paperless-GPT   → http://${HOST_IP}:8081"
echo -e "    Paperless-AI    → http://${HOST_IP}:3000"
echo ""

read -rp "$(echo -e "${CYAN}?${NC}  Proceed with installation? [Y/n]: ")" CONFIRM
if [[ "${CONFIRM,,}" =~ ^(n|no)$ ]]; then
    warn "Installation cancelled."
    exit 0
fi

INSTALL_FAILED=true

# ─── Create Directory Structure ──────────────────────────────────────────────
header "Setting Up"
info "Creating directory structure..."
mkdir -p "${INSTALL_DIR}"/{data,media,export,consume,pgdata,redis,prompts}
ok "Created $INSTALL_DIR"

# ─── Generate Docker Compose ─────────────────────────────────────────────────
info "Generating docker-compose.yaml..."

# Build OCR_LANGUAGES (space-separated from + format)
OCR_LANGUAGES_SPACE=$(echo "$OCR_LANGS" | tr '+' ' ')

# Build Ollama env block for paperless-gpt
OLLAMA_GPT_ENV=""
EXTRA_HOSTS_GPT=""
EXTRA_HOSTS_AI=""
if [[ "${USE_OLLAMA,,}" =~ ^(y|yes)$ ]]; then
    OLLAMA_GPT_ENV=$(cat << OLLAMAEOF
      # LLM via Ollama
      LLM_PROVIDER: "ollama"
      LLM_MODEL: "${LLM_MODEL}"
      LLM_LANGUAGE: "${LLM_LANGUAGE}"
      OCR_PROVIDER: "llm"
      VISION_LLM_PROVIDER: "ollama"
      VISION_LLM_MODEL: "${VISION_MODEL}"
      OLLAMA_HOST: "${OLLAMA_DOCKER_URL}"
      OLLAMA_CONTEXT_LENGTH: "8192"
OLLAMAEOF
)
    EXTRA_HOSTS_GPT='    extra_hosts:
      - "host.docker.internal:host-gateway"'
    EXTRA_HOSTS_AI='    extra_hosts:
      - "host.docker.internal:host-gateway"'
fi

cat > "${INSTALL_DIR}/docker-compose.yaml" << COMPOSEEOF
# =============================================================================
# Paperless AI Stack — Auto-generated by paperless-ai-stack.sh
# Generated: $(date -Iseconds)
# =============================================================================

services:
  # ──────────────────────────────────────────────────────────────────────────
  # PostgreSQL 16 — Database
  # ──────────────────────────────────────────────────────────────────────────
  postgres:
    image: docker.io/postgres:16
    container_name: paperless-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: paperless
      POSTGRES_USER: paperless
      POSTGRES_PASSWORD: paperless
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U paperless -d paperless"]
      interval: 5s
      timeout: 10s
      retries: 5

  # ──────────────────────────────────────────────────────────────────────────
  # Redis 7 — Message Broker
  # ──────────────────────────────────────────────────────────────────────────
  redis:
    image: docker.io/redis:7-alpine
    container_name: paperless-redis
    restart: unless-stopped
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 10s
      retries: 5

  # ──────────────────────────────────────────────────────────────────────────
  # Paperless-ngx — Document Management System
  # ──────────────────────────────────────────────────────────────────────────
  paperless-ngx:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    container_name: paperless-ngx
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      PAPERLESS_DBHOST: postgres
      PAPERLESS_DBNAME: paperless
      PAPERLESS_DBUSER: paperless
      PAPERLESS_DBPASS: paperless
      PAPERLESS_REDIS: redis://redis:6379
      PAPERLESS_SECRET_KEY: "${SECRET_KEY}"
      PAPERLESS_ADMIN_USER: "${ADMIN_USER}"
      PAPERLESS_ADMIN_PASSWORD: "${ADMIN_PASS}"
      PAPERLESS_TIME_ZONE: "${TIMEZONE}"
      PAPERLESS_OCR_LANGUAGE: "${OCR_LANGS}"
      PAPERLESS_OCR_LANGUAGES: "${OCR_LANGUAGES_SPACE}"
      PAPERLESS_TASK_WORKERS: 2
      PAPERLESS_THREADS_PER_WORKER: 2
      PAPERLESS_URL: "http://${HOST_IP}:8000"
    volumes:
      - ./data:/usr/src/paperless/data
      - ./media:/usr/src/paperless/media
      - ./export:/usr/src/paperless/export
      - ./consume:/usr/src/paperless/consume
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8000 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  # ──────────────────────────────────────────────────────────────────────────
  # Paperless-GPT — LLM-powered OCR & Auto-Tagging
  # ──────────────────────────────────────────────────────────────────────────
  paperless-gpt:
    image: icereed/paperless-gpt:latest
    container_name: paperless-gpt
    restart: unless-stopped
    ports:
      - "8081:8080"
    environment:
      PAPERLESS_BASE_URL: "http://paperless-ngx:8000"
      PAPERLESS_API_TOKEN: "__PAPERLESS_TOKEN__"
${OLLAMA_GPT_ENV}
      # Processing
      OCR_PROCESS_MODE: "image"
      PDF_SKIP_EXISTING_OCR: "false"
      LOG_LEVEL: "info"
      # Tags
      MANUAL_TAG: "paperless-gpt"
      AUTO_TAG: "paperless-gpt-auto"
      AUTO_OCR_TAG: "paperless-gpt-ocr-auto"
      # PDF output
      CREATE_LOCAL_PDF: "false"
      CREATE_LOCAL_HOCR: "false"
      PDF_UPLOAD: "false"
      PDF_REPLACE: "false"
      PDF_COPY_METADATA: "true"
      PDF_OCR_TAGGING: "true"
      PDF_OCR_COMPLETE_TAG: "paperless-gpt-ocr-complete"
      TOKEN_LIMIT: "4000"
    volumes:
      - ./prompts:/app/prompts
    depends_on:
      paperless-ngx:
        condition: service_healthy
${EXTRA_HOSTS_GPT}

  # ──────────────────────────────────────────────────────────────────────────
  # Paperless-AI — Auto Classification & RAG Chat
  # ──────────────────────────────────────────────────────────────────────────
  paperless-ai:
    image: clusterzx/paperless-ai:latest
    container_name: paperless-ai
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      PUID: "1000"
      PGID: "1000"
    volumes:
      - paperless-ai_data:/app/data
${EXTRA_HOSTS_AI}

volumes:
  paperless-ai_data:
COMPOSEEOF

ok "Generated docker-compose.yaml"

# ─── Validate Docker Compose ─────────────────────────────────────────────────
info "Validating docker-compose.yaml..."
cd "${INSTALL_DIR}"
if $COMPOSE_CMD config --quiet 2>/dev/null; then
    ok "Docker Compose file is valid"
else
    $COMPOSE_CMD config >/dev/null 2>&1 || {
        err "Docker Compose file has errors!"
        $COMPOSE_CMD config 2>&1 | tail -5
        exit 1
    }
    ok "Docker Compose file is valid"
fi

# ─── Pull Images ──────────────────────────────────────────────────────────────
header "Pulling Docker Images"
info "This may take a few minutes on first run..."
$COMPOSE_CMD pull
ok "All images pulled"

# ─── Start Core Services First ────────────────────────────────────────────────
header "Starting Services"
info "Starting database and core services..."
$COMPOSE_CMD up -d postgres redis
info "Waiting for PostgreSQL to be ready..."

# Wait for postgres health
RETRIES=0
while [ $RETRIES -lt 30 ]; do
    if docker inspect --format='{{.State.Health.Status}}' paperless-postgres 2>/dev/null | grep -q healthy; then
        break
    fi
    RETRIES=$((RETRIES + 1))
    sleep 2
done
ok "PostgreSQL is ready"

# Start paperless-ngx
info "Starting Paperless-ngx..."
$COMPOSE_CMD up -d paperless-ngx
info "Waiting for Paperless-ngx to initialize (this takes ~30-60s on first run)..."

# Wait for paperless-ngx to be healthy
RETRIES=0
MAX_RETRIES=60
while [ $RETRIES -lt $MAX_RETRIES ]; do
    if curl -sS --max-time 3 "http://localhost:8000" &>/dev/null; then
        break
    fi
    RETRIES=$((RETRIES + 1))
    sleep 3
    printf "\r  Waiting... (%d/%d)" "$RETRIES" "$MAX_RETRIES"
done
echo ""

if [ $RETRIES -ge $MAX_RETRIES ]; then
    err "Paperless-ngx did not become healthy in time"
    warn "Check logs: $COMPOSE_CMD logs paperless-ngx"
    exit 1
fi
ok "Paperless-ngx is running"

# ─── Generate API Token ──────────────────────────────────────────────────────
info "Generating Paperless-ngx API token..."

# Wait a moment for Django to fully initialize
sleep 5

API_TOKEN=""
for attempt in 1 2 3; do
    API_TOKEN=$(docker exec paperless-ngx python3 manage.py shell -c "
from rest_framework.authtoken.models import Token
from django.contrib.auth.models import User
t, _ = Token.objects.get_or_create(user=User.objects.get(username='${ADMIN_USER}'))
print(t.key)
" 2>/dev/null | grep -E '^[a-f0-9]{40}$' || true)
    if [ -n "$API_TOKEN" ]; then
        break
    fi
    info "Retrying token generation (attempt $attempt/3)..."
    sleep 5
done

if [ -z "$API_TOKEN" ]; then
    err "Failed to generate API token"
    warn "You'll need to manually set the token in docker-compose.yaml"
    warn "Run: docker exec paperless-ngx python3 manage.py shell"
    warn "Then: from rest_framework.authtoken.models import Token; from django.contrib.auth.models import User; t,_=Token.objects.get_or_create(user=User.objects.get(username='admin')); print(t.key)"
else
    ok "API Token: $API_TOKEN"
    # Update docker-compose with real token
    sed -i "s/__PAPERLESS_TOKEN__/${API_TOKEN}/" "${INSTALL_DIR}/docker-compose.yaml"
    ok "Updated docker-compose.yaml with API token"
fi

# ─── Start remaining services ─────────────────────────────────────────────────
info "Starting Paperless-GPT and Paperless-AI..."
$COMPOSE_CMD up -d
ok "All services started"

# ─── Health Check ─────────────────────────────────────────────────────────────
header "Health Check"
info "Waiting for all services to stabilize..."
sleep 10
echo ""
$COMPOSE_CMD ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || $COMPOSE_CMD ps
echo ""

# Final checks
ALL_OK=true
for svc in paperless-postgres paperless-redis paperless-ngx paperless-gpt paperless-ai; do
    STATUS=$(docker inspect --format='{{.State.Running}}' "$svc" 2>/dev/null || echo "false")
    if [ "$STATUS" = "true" ]; then
        ok "$svc is running"
    else
        err "$svc is NOT running — check: docker logs $svc"
        ALL_OK=false
    fi
done

# ─── Save Credentials ────────────────────────────────────────────────────────
CREDS_FILE="${INSTALL_DIR}/.credentials"
cat > "$CREDS_FILE" << CREDSEOF
# Paperless AI Stack — Credentials
# Generated: $(date -Iseconds)
# ─────────────────────────────────
Admin Username:  ${ADMIN_USER}
Admin Password:  ${ADMIN_PASS}
API Token:       ${API_TOKEN:-NOT_GENERATED}
Secret Key:      ${SECRET_KEY}

Paperless-ngx:   http://${HOST_IP}:8000
Paperless-GPT:   http://${HOST_IP}:8081
Paperless-AI:    http://${HOST_IP}:3000
CREDSEOF
chmod 600 "$CREDS_FILE"

INSTALL_FAILED=false

# ─── Done ─────────────────────────────────────────────────────────────────────
header "Installation Complete!"
echo ""
echo -e "  ${BOLD}${GREEN}🎉 Paperless AI Stack is ready!${NC}"
echo ""
echo -e "  ${BOLD}Access:${NC}"
echo -e "    📄 Paperless-ngx   → ${CYAN}http://${HOST_IP}:8000${NC}"
echo -e "    🤖 Paperless-GPT   → ${CYAN}http://${HOST_IP}:8081${NC}"
echo -e "    🧠 Paperless-AI    → ${CYAN}http://${HOST_IP}:3000${NC}"
echo ""
echo -e "  ${BOLD}Login:${NC}  ${ADMIN_USER} / ${ADMIN_PASS}"
echo -e "  ${BOLD}API Token:${NC}  ${API_TOKEN:-Check ${CREDS_FILE}}"
echo ""
echo -e "  ${BOLD}Files:${NC}"
echo -e "    Config:       ${INSTALL_DIR}/docker-compose.yaml"
echo -e "    Credentials:  ${CREDS_FILE}"
echo -e "    Documents:    ${INSTALL_DIR}/consume/ (drop files here)"
echo ""
if [[ "${USE_OLLAMA,,}" =~ ^(y|yes)$ ]]; then
    echo -e "  ${BOLD}AI:${NC}"
    echo -e "    Ollama:       ${OLLAMA_URL}"
    echo -e "    LLM Model:    ${LLM_MODEL}"
    echo -e "    Vision Model: ${VISION_MODEL}"
    echo ""
fi
echo -e "  ${BOLD}Next Steps:${NC}"
echo -e "    1. Open Paperless-ngx and upload a document"
echo -e "    2. Tag it with '${YELLOW}paperless-gpt${NC}' to trigger AI processing"
echo -e "    3. Configure Paperless-AI at http://${HOST_IP}:3000 (first-run setup)"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo -e "    cd ${INSTALL_DIR}"
echo -e "    ${COMPOSE_CMD} logs -f          # View logs"
echo -e "    ${COMPOSE_CMD} restart           # Restart all"
echo -e "    ${COMPOSE_CMD} down              # Stop all"
echo -e "    ${COMPOSE_CMD} up -d             # Start all"
echo ""

if [ "$ALL_OK" = true ]; then
    ok "All services healthy. Enjoy! 🚀"
else
    warn "Some services may need attention. Check logs above."
fi
