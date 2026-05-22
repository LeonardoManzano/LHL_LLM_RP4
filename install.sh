#!/usr/bin/env bash
# Install Ollama on an Orange Pi 4 Pro (Allwinner A733, ARM64, 12GB LPDDR5)
# and configure it as a LAN-accessible LLM API service.
#
# Idempotent: safe to re-run.
# Run: ./install.sh   (will use sudo internally; do not invoke with sudo)

set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen2.5:7b-instruct-q4_0}"
MODEL_FALLBACK="qwen2.5:7b"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
HEALTH_URL="http://127.0.0.1:${OLLAMA_PORT}/api/version"
GOVERNOR_UNIT="/etc/systemd/system/cpu-performance.service"
SWAPPINESS_CONF="/etc/sysctl.d/99-ollama-swappiness.conf"

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

# Detect the highest-frequency cores. On big.LITTLE ARM SoCs this is the "big"
# cluster. On homogeneous SoCs every core matches the max — return all of them.
# Output: comma-separated CPU IDs, e.g. "4,5,6,7" or "0,1,2,3,4,5,6,7".
detect_big_cores() {
  local max_freq f cpu_id big_list=""
  max_freq=$(cat /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq 2>/dev/null | sort -un | tail -1)
  if [ -z "$max_freq" ]; then
    # cpufreq not exposed (rare) — fall back to all cores
    echo "0-$(($(nproc)-1))"
    return
  fi
  for f in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq; do
    if [ "$(cat "$f")" = "$max_freq" ]; then
      cpu_id=$(echo "$f" | grep -oP 'cpu\K[0-9]+')
      big_list="${big_list:+$big_list,}$cpu_id"
    fi
  done
  echo "$big_list"
}

# ---------- step 1: preflight ----------
step "1/10" "Preflight checks"
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

BIG_CORES="$(detect_big_cores)"
NUM_BIG="$(echo "$BIG_CORES" | tr ',-' '\n\n' | grep -c .)"
ok "perf cores: ${BIG_CORES} (${NUM_BIG} threads)"

# ---------- step 2: apt deps ----------
step "2/10" "Installing base packages (curl, ca-certificates, jq)"
$SUDO apt-get update -qq
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates jq >/dev/null
ok "apt packages installed"

# ---------- step 3: install ollama ----------
step "3/10" "Installing Ollama"
if command -v ollama >/dev/null 2>&1 && systemctl is-enabled --quiet ollama 2>/dev/null; then
  ok "Ollama already installed ($(ollama --version 2>/dev/null | head -n1)) — skipping installer"
else
  curl -fsSL https://ollama.com/install.sh | $SUDO sh
  ok "Ollama installed"
fi

# ---------- step 4: CPU governor → performance ----------
step "4/10" "Pinning CPU governor to performance (persistent)"
NEW_GOVERNOR_UNIT="$(cat <<'EOF'
[Unit]
Description=Set all CPUs to performance governor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
)"
if [ -f "$GOVERNOR_UNIT" ] && [ "$($SUDO cat "$GOVERNOR_UNIT" 2>/dev/null)" = "$NEW_GOVERNOR_UNIT" ]; then
  ok "cpu-performance.service unchanged"
else
  printf '%s\n' "$NEW_GOVERNOR_UNIT" | $SUDO tee "$GOVERNOR_UNIT" >/dev/null
  $SUDO systemctl daemon-reload
  ok "cpu-performance.service written"
fi
$SUDO systemctl enable --now cpu-performance.service >/dev/null 2>&1 || warn "could not enable cpu-performance.service"
CURRENT_GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
ok "governor on cpu0: ${CURRENT_GOV}"

# ---------- step 5: disable swap + zram ----------
step "5/10" "Disabling swap and zram (dedicated LLM box)"
if [ "$(swapon --show=NAME --noheadings 2>/dev/null | wc -l)" -gt 0 ]; then
  $SUDO swapoff -a || warn "swapoff failed"
  ok "swap turned off"
else
  ok "swap already off"
fi
# Comment out any uncommented swap line in /etc/fstab so it doesn't come back at boot.
if grep -qE '^[^#].*\sswap\s' /etc/fstab 2>/dev/null; then
  $SUDO sed -i.bak -E 's@^([^#].*\sswap\s.*)$@#\1@' /etc/fstab
  ok "swap lines in /etc/fstab commented (backup: /etc/fstab.bak)"
else
  ok "/etc/fstab swap lines already absent or commented"
fi
NEW_SWAPPINESS="vm.swappiness=1"
if [ -f "$SWAPPINESS_CONF" ] && [ "$($SUDO cat "$SWAPPINESS_CONF" 2>/dev/null)" = "$NEW_SWAPPINESS" ]; then
  ok "vm.swappiness already pinned to 1"
else
  printf '%s\n' "$NEW_SWAPPINESS" | $SUDO tee "$SWAPPINESS_CONF" >/dev/null
  $SUDO sysctl --system >/dev/null
  ok "vm.swappiness=1 applied"
fi
# zram is often bundled on Orange Pi images and competes for cores with inference.
if systemctl list-unit-files 2>/dev/null | grep -qE '^(zramswap|armbian-zram-config)\.service'; then
  $SUDO systemctl disable --now zramswap.service armbian-zram-config.service >/dev/null 2>&1 || true
  ok "zram disabled"
fi

# ---------- step 6: systemd override ----------
step "6/10" "Configuring systemd override (bind ${OLLAMA_PORT} on 0.0.0.0, tuning for ARM CPU)"
$SUDO mkdir -p "$OVERRIDE_DIR"
NEW_OVERRIDE="$(cat <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_NUM_THREAD=${NUM_BIG}"
CPUAffinity=${BIG_CORES}
LimitMEMLOCK=infinity
Nice=-5
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

# ---------- step 7: health wait ----------
step "7/10" "Waiting for Ollama API to come up"
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

# ---------- step 8: pull model ----------
step "8/10" "Pulling default model: ${MODEL}"
present() { ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1\(:latest\)\?"; }
if present "$MODEL"; then
  ok "${MODEL} already present — skipping pull"
elif ollama pull "$MODEL"; then
  ok "${MODEL} pulled"
else
  warn "pull of ${MODEL} failed — falling back to ${MODEL_FALLBACK}"
  if present "$MODEL_FALLBACK"; then
    ok "${MODEL_FALLBACK} already present"
  else
    ollama pull "$MODEL_FALLBACK"
    ok "${MODEL_FALLBACK} pulled"
  fi
  MODEL="$MODEL_FALLBACK"
fi

# ---------- step 9: throughput benchmark ----------
step "9/10" "Throughput benchmark"
BENCH_PROMPT="Write a 200-word essay about computer networking fundamentals."
RESPONSE_JSON="$(curl -fsS --max-time 300 "http://127.0.0.1:${OLLAMA_PORT}/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"${BENCH_PROMPT}\",\"stream\":false}")"
RESPONSE_TEXT="$(printf '%s' "$RESPONSE_JSON" | jq -r '.response // empty')"
if [ -z "$RESPONSE_TEXT" ]; then
  printf "Raw response: %s\n" "$RESPONSE_JSON" >&2
  die "Benchmark failed — empty .response field"
fi
TOK_S="$(printf '%s' "$RESPONSE_JSON" | jq -r '
  if (.eval_count != null and .eval_duration != null and .eval_duration > 0)
  then (.eval_count / (.eval_duration / 1e9)) | floor
  else 0
  end
')"
EVAL_COUNT="$(printf '%s' "$RESPONSE_JSON" | jq -r '.eval_count // 0')"
ok "model replied with ${EVAL_COUNT} tokens → ~${TOK_S} tok/s on ${MODEL}"

# ---------- step 10: summary ----------
step "10/10" "Done"

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
