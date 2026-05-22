# LHL_LLM_RP4 — LLM install for Orange Pi 4 Pro

One-shot install script that turns an **Orange Pi 4 Pro** (Allwinner A733, 8-core ARM64, 12GB LPDDR5) into a LAN-accessible LLM API server using [Ollama](https://ollama.com).

Designed for a fleet — same script, run once on each board. Each board is independent.

## Quickstart

On each Orange Pi (Ubuntu/Debian ARM64):

```bash
# Optional but recommended: give each board a distinct name first
sudo hostnamectl set-hostname orangepi-llm-1   # use 1..5 per board

# Clone and run
git clone <this-repo> ~/LHL_LLM_RP4
cd ~/LHL_LLM_RP4
./install.sh
```

The script is idempotent — safe to re-run. Total runtime is ~3–5 minutes (the model pull is most of it).

When it finishes you'll see the board's LAN IP and a `curl` example you can paste from another machine.

## Calling the API

Native Ollama endpoint:

```bash
curl http://<board-ip>:11434/api/generate \
  -d '{"model":"phi3.5","prompt":"Hello!","stream":false}'
```

OpenAI-compatible endpoint (works with any OpenAI SDK — set `base_url` to `http://<board-ip>:11434/v1` and any string as `api_key`):

```bash
curl http://<board-ip>:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"phi3.5","messages":[{"role":"user","content":"Hello!"}]}'
```

## Model sizing for 12GB RAM

The script pre-pulls **Qwen 2.5 7B (Q4_0)** (~4.4GB) as a daily-driver. Q4_0 is used instead of the default Q4_K_M tag because llama.cpp's NEON kernels are faster for legacy 4-bit formats on ARM Cortex-A class cores. You can pull more anytime:

| Model | Pull command | Size | Speed | Notes |
|---|---|---|---|---|
| Llama 3.2 3B | `ollama pull llama3.2:3b-instruct-q4_0` | ~2 GB | ~10–15 tok/s | Snappy general chat |
| Phi-3.5 Mini | `ollama pull phi3.5` | ~2.3 GB | ~10–15 tok/s | Strong reasoning for size |
| Qwen 2.5 7B Q4_0 (default) | `ollama pull qwen2.5:7b-instruct-q4_0` | ~4.4 GB | ~6–8 tok/s | Best quality/speed tradeoff on this hardware |
| Llama 3.1 8B | `ollama pull llama3.1:8b-instruct-q4_0` | ~4.7 GB | ~5–7 tok/s | Most capable single-node option |
| Gemma 2 9B | `ollama pull gemma2:9b` | ~5.5 GB | ~3–5 tok/s | Capable but heavier |
| Anything ≥ 13B | — | ≥ 8 GB | sluggish | Not recommended single-node |

Speeds are rough CPU-only estimates **with the tunings this script applies** (performance governor, flash attention, KV cache q8_0, big-core pinning, no swap). On stock settings expect ~30–50% lower. The script sets `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_KEEP_ALIVE=24h` so the active model stays hot and RAM stays free for everything else.

## What about the NPU?

The Allwinner A733's 3 TOPS NPU **is not used**. Neither Ollama nor llama.cpp support that NPU today; both run on the 8 ARM Cortex cores using NEON SIMD. Don't expect NPU-class throughput — expect competent CPU inference of small/medium quantized models.

## Configuration

The script writes `/etc/systemd/system/ollama.service.d/override.conf` with:

```
OLLAMA_HOST=0.0.0.0:11434       # LAN-accessible
OLLAMA_KEEP_ALIVE=24h            # keep the active model hot (dedicated box)
OLLAMA_NUM_PARALLEL=1            # avoid CPU thrashing
OLLAMA_MAX_LOADED_MODELS=1       # only one model in RAM
OLLAMA_FLASH_ATTENTION=1         # faster attention + lower KV memory
OLLAMA_KV_CACHE_TYPE=q8_0        # quantized KV cache (needs flash attention)
OLLAMA_NUM_THREAD=<num_big>      # auto-detected: count of highest-freq cores
CPUAffinity=<big_cores>          # auto-detected: pin to performance cluster
LimitMEMLOCK=infinity            # allow mlock of model pages
Nice=-5                          # small scheduling priority bump
```

It also installs `/etc/systemd/system/cpu-performance.service` to pin every core to the `performance` governor on boot, disables swap and zram, and pins `vm.swappiness=1`. These are appropriate for a dedicated LLM box — re-enable them manually if you intend to run other workloads on the same Pi.

Override the model or port at install time:

```bash
OLLAMA_MODEL=llama3.1:8b-instruct-q4_0 OLLAMA_PORT=11434 ./install.sh
```

## Troubleshooting

```bash
# Service status / live logs
systemctl status ollama
journalctl -u ollama -f

# Confirm it's listening on the LAN, not just localhost
ss -tlnp | grep 11434

# Re-run install (idempotent)
./install.sh

# List / remove models
ollama list
ollama rm <model>
```

If the API is unreachable from another machine, check the board's firewall (`sudo ufw status`) and your router/AP's client-isolation setting.

## Verifying the tuning took effect

```bash
# Tuning env vars and affinity loaded?
systemctl cat ollama | grep -E 'FLASH_ATTENTION|KV_CACHE|NUM_THREAD|CPUAffinity|MEMLOCK'

# All cores in performance governor?
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Swap really off?
swapon --show         # expect empty
sysctl vm.swappiness  # expect 1

# Measure tok/s for the current model
curl -s http://127.0.0.1:11434/api/generate \
  -d '{"model":"qwen2.5:7b-instruct-q4_0","prompt":"Write 200 words about computer networking.","stream":false}' \
  | jq -r '"\(.eval_count) tok in \((.eval_duration/1e9)) s = \((.eval_count/(.eval_duration/1e9))|floor) tok/s"'

# Thermals during a long generation (run alongside the curl above in another shell)
watch -n1 'cat /sys/class/thermal/thermal_zone*/temp'
```

Sustained CPU temps above ~80C mean the fan isn't keeping up — even with active cooling, expect throttling and double-digit-percent tok/s losses.
