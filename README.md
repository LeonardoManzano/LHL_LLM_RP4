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

The script pre-pulls **Phi-3.5 Mini** (~2.3GB, fast). You can pull more anytime:

| Model | Pull command | Size (Q4) | Speed | Notes |
|---|---|---|---|---|
| Llama 3.2 3B | `ollama pull llama3.2:3b` | ~2 GB | ~10–15 tok/s | Snappy general chat |
| Phi-3.5 Mini (default) | `ollama pull phi3.5` | ~2.3 GB | ~10–15 tok/s | Strong reasoning for size |
| Qwen 2.5 7B | `ollama pull qwen2.5:7b` | ~4.7 GB | ~4–7 tok/s | Best quality/speed tradeoff |
| Llama 3.1 8B | `ollama pull llama3.1:8b` | ~4.9 GB | ~3–6 tok/s | Most capable single-node option |
| Gemma 2 9B | `ollama pull gemma2:9b` | ~5.5 GB | ~3–5 tok/s | Capable but heavier |
| Anything ≥ 13B | — | ≥ 8 GB | sluggish | Not recommended single-node |

Speeds are rough CPU-only estimates for this hardware. The script sets `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_KEEP_ALIVE=5m` so RAM frees up between sessions — pulling many models is fine, only one is resident at a time.

## What about the NPU?

The Allwinner A733's 3 TOPS NPU **is not used**. Neither Ollama nor llama.cpp support that NPU today; both run on the 8 ARM Cortex cores using NEON SIMD. Don't expect NPU-class throughput — expect competent CPU inference of small/medium quantized models.

## Configuration

The script writes `/etc/systemd/system/ollama.service.d/override.conf` with:

```
OLLAMA_HOST=0.0.0.0:11434      # LAN-accessible
OLLAMA_KEEP_ALIVE=5m            # unload idle models
OLLAMA_NUM_PARALLEL=1           # avoid CPU thrashing
OLLAMA_MAX_LOADED_MODELS=1      # only one model in RAM
```

Override the model or port at install time:

```bash
OLLAMA_MODEL=qwen2.5:7b OLLAMA_PORT=11434 ./install.sh
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
