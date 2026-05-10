#!/usr/bin/env bash
# Install Ollama on an Orange Pi 4 Pro (Allwinner A733, ARM64, 12GB LPDDR5)
# and configure it as a LAN-accessible LLM API service.
#
# Idempotent: safe to re-run.
# Run: ./install.sh   (will use sudo internally; do not invoke with sudo)

set -euo pipefail

MODEL="${OLLAMA_MODEL:-phi3.5}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
HEALTH_URL="http://127.0.0.1:${OLLAMA_PORT}/api/version"

C_RESET="$(printf '\033[0m')"
C_BOLD="$(printf '\033[1m')"
C_GREEN="$(printf '\033[32m')"
C_YELLOW="$(printf '\033[33m')"
C_RED="$(printf '\033[31m')"
C_BLUE="$(printf '\033[34m')"

step()  { printf "\n%s[step %s]%s %s\n" "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}" "$2"; }
ok()    { printf "  %s✓%s %s\n" "${C_GREEN}" "${C_RESET}" "$1"; }
warn()  { printf "  %s!%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1"; }
die()   { printf "  %s✗%s %s\n" "${C_RED}" "${C_RESET}" "$1" >&2; exit 1; }

require_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    # Allow root, but prefer non-root + sudo. Don't abort.
    SUDO=""
  else
    if ! command -v sudo >/dev/null 2>&1; then
      die "sudo not found; install sudo or run as root"
    fi
    SUDO="sudo"
    # Prime sudo so subsequent calls don't prompt mid-install.
    $SUDO -v || die "sudo authentication failed"
  fi
}

# ---------- step 1: preflight ----------
step "1/8" "Preflight checks"
require_sudo

ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || die "Expected aarch64 (ARM64), got '$ARCH'. This script targets Orange Pi 4 Pro."
ok "architecture: aarch64"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:*debian*|*:*ubuntu*) ok "OS: ${PRETTY_NAME:-$ID}" ;;
    *) warn "OS '${PRETTY_NAME:-unknown}' is not Debian/Ubuntu — proceeding anyway" ;;
  esac
else
  warn "/etc/os-release missing — cannot verify distro"
fi

MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
MEM_GB=$(( MEM_KB / 1024 / 1024 ))
if [ "$MEM_GB" -lt 8 ]; then
  warn "Only ${MEM_GB}GB RAM detected (expected ~12GB). Larger models may OOM."
else
  ok "RAM: ${MEM_GB}GB"
fi

DISK_FREE_GB="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"
if [ "${DISK_FREE_GB:-0}" -lt 10 ]; then
  die "Less than 10GB free on / (have ${DISK_FREE_GB}GB). Need room for Ollama + model."
fi
ok "disk free on /: ${DISK_FREE_GB}GB"

if ! curl -fsS --max-time 5 -o /dev/null https://ollama.com; then
  die "Cannot reach https://ollama.com — check network/DNS"
fi
ok "network: ollama.com reachable"

# ---------- step 2: apt deps ----------
step "2/8" "Installing base packages (curl, ca-certificates, jq)"
$SUDO apt-get update -qq
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates jq >/dev/null
ok "apt packages installed"

# ---------- step 3: install ollama ----------
step "3/8" "Installing Ollama"
if command -v ollama >/dev/null 2>&1 && systemctl is-enabled --quiet ollama 2>/dev/null; then
  ok "Ollama already installed ($(ollama --version 2>/dev/null | head -n1)) — skipping installer"
else
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  ok "Ollama installed"
fi

# ---------- step 4: systemd override ----------
step "4/8" "Configuring systemd override (bind ${OLLAMA_PORT} on 0.0.0.0)"
$SUDO mkdir -p "$OVERRIDE_DIR"
NEW_OVERRIDE="$(cat <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
)"

CHANGED=1
if [ -f "$OVERRIDE_FILE" ] && [ "$($SUDO cat "$OVERRIDE_FILE" 2>/dev/null)" = "$NEW_OVERRIDE" ]; then
  CHANGED=0
  ok "override.conf unchanged"
fi

if [ "$CHANGED" = "1" ]; then
  printf '%s\n' "$NEW_OVERRIDE" | $SUDO tee "$OVERRIDE_FILE" >/dev/null
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now ollama >/dev/null 2>&1 || true
  $SUDO systemctl restart ollama
  ok "override.conf written and ollama restarted"
fi

# ---------- step 5: health wait ----------
step "5/8" "Waiting for Ollama API to come up"
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "API healthy at ${HEALTH_URL} (after ${i}s)"
    break
  fi
  if [ "$i" -eq 30 ]; then
    printf "\n%s--- last 50 lines of journalctl -u ollama ---%s\n" "${C_YELLOW}" "${C_RESET}"
    $SUDO journalctl -u ollama -n 50 --no-pager || true
    die "Ollama API never became healthy on ${HEALTH_URL}"
  fi
  sleep 1
done

# ---------- step 6: pull model ----------
step "6/8" "Pulling default model: ${MODEL}"
if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${MODEL}\(:latest\)\?"; then
  ok "${MODEL} already present — skipping pull"
else
  ollama pull "$MODEL"
  ok "${MODEL} pulled"
fi

# ---------- step 7: smoke test ----------
step "7/8" "Smoke test"
RESPONSE_JSON="$(curl -fsS --max-time 120 "http://127.0.0.1:${OLLAMA_PORT}/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"Say hi in five words.\",\"stream\":false}")"
RESPONSE_TEXT="$(printf '%s' "$RESPONSE_JSON" | jq -r '.response // empty')"
if [ -z "$RESPONSE_TEXT" ]; then
  printf "Raw response: %s\n" "$RESPONSE_JSON" >&2
  die "Smoke test failed — empty .response field"
fi
ok "model replied: $(printf '%s' "$RESPONSE_TEXT" | tr '\n' ' ' | cut -c1-80)"

# ---------- step 8: summary ----------
step "8/8" "Done"

HOST="$(hostname)"
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
LAN_IP="${LAN_IP:-<this-board-ip>}"

cat <<EOF

${C_BOLD}${C_GREEN}Ollama is up on ${HOST}${C_RESET}
  API:          http://${LAN_IP}:${OLLAMA_PORT}
  Default model: ${MODEL}

${C_BOLD}Call from another machine on the LAN:${C_RESET}
  curl http://${LAN_IP}:${OLLAMA_PORT}/api/generate \\
    -d '{"model":"${MODEL}","prompt":"Hello!","stream":false}'

${C_BOLD}OpenAI-compatible endpoint:${C_RESET}
  curl http://${LAN_IP}:${OLLAMA_PORT}/v1/chat/completions \\
    -H "Content-Type: application/json" \\
    -d '{"model":"${MODEL}","messages":[{"role":"user","content":"Hello!"}]}'

${C_BOLD}Pull more models (12GB RAM headroom):${C_RESET}
  ollama pull llama3.2:3b      # ~2GB,  fast
  ollama pull qwen2.5:7b       # ~4.7GB, sweet spot
  ollama pull llama3.1:8b      # ~4.9GB, capable

${C_BOLD}Note:${C_RESET} The Allwinner A733's 3 TOPS NPU is not used —
Ollama runs on the 8 ARM cores via NEON SIMD.

EOF
