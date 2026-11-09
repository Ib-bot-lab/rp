#!/usr/bin/env bash
# One-shot setup for MiniMax H3 character swap on a fresh RunPod ComfyUI pod.
# No persistent volume needed. Re-run from scratch on every new pod.
# Requires: NVIDIA GPU with 24GB+ VRAM, container disk >= 80GB.
set -euo pipefail

log() { echo; echo "=== $* ==="; }

log "Locating ComfyUI"
COMFY=""
for c in /workspace/runpod-slim/ComfyUI /workspace/ComfyUI /ComfyUI /opt/comfyui-baked; do
  if [ -f "$c/comfyui_version.py" ]; then COMFY="$c"; break; fi
done
[ -n "$COMFY" ] || { echo "ComfyUI not found. Run: find / -name comfyui_version.py"; exit 1; }
echo "$COMFY"

if [ -z "${VIRTUAL_ENV:-}" ]; then
  V="$(find "$COMFY" -maxdepth 1 -type d -name '.venv*' | head -1)"
  [ -n "$V" ] && { echo "activating $V"; . "$V/bin/activate"; }
fi

command -v ffmpeg >/dev/null || { echo "ffmpeg missing from PATH"; exit 1; }
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

log "Pinning ComfyUI to v0.44.2 (h3-relay needs 0.37.0+)"
cd "$COMFY"
git fetch --all --tags --quiet
git reset --hard v0.44.2
pip install -q -r requirements.txt

log "Installing h3-relay"
mkdir -p "$COMFY/custom_nodes"
rm -rf "$COMFY/custom_nodes/h3-relay"
git clone --quiet https://github.com/akatz-ai/h3-relay.git "$COMFY/custom_nodes/h3-relay"
pip install -q -r "$COMFY/custom_nodes/h3-relay/requirements.txt" 2>/dev/null || true

log "Downloading models (46GB)"
pip install -q -U "huggingface_hub[cli]" hf_transfer
export HF_HUB_ENABLE_HF_TRANSFER=1
M="$COMFY/models"

# These repos mirror ComfyUI's folder layout, so files land in the right place.
hf download Comfy-Org/MiniMax-H3 \
  diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  vae/minimax_h3_video_vae_fp16.safetensors \
  vae/minimax_h3_audio_vae_fp32.safetensors \
  --local-dir "$M"

hf download Comfy-Org/sam3.1 \
  checkpoints/sam3.1_multiplex_fp16.safetensors --local-dir "$M"

hf download lightx2v/Minimax-h3-Turbo \
  minimax_h3_fl2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors --local-dir "$M/loras"

hf download akatz-ai/MiniMax-H3-Character-Swap-LoRA \
  h3_character_swap_v1.5.safetensors --local-dir "$M/loras"

# The shipped workflow references the adapter at this path.
mkdir -p "$M/loras/h3-v2-challenge-eval-20261013"
ln -sf "$M/loras/h3_character_swap_v1.5.safetensors" \
       "$M/loras/h3-v2-challenge-eval-20261013/v2-1000.safetensors"

log "Making the workflow visible in the UI sidebar"
mkdir -p "$COMFY/user/default/workflows"
cp "$COMFY/custom_nodes/h3-relay/example_workflows/toolkit/H3-Character-Swap.json" \
   "$COMFY/user/default/workflows/"

log "Verifying"
find "$M" -name '*.safetensors' -printf '%10s  %p\n' | sort -rn

log "Restarting ComfyUI"
pkill -f "main.py --listen" || true
sleep 5
cd "$COMFY"
nohup python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header \
  > /tmp/comfyui.log 2>&1 &
sleep 30
tail -25 /tmp/comfyui.log

log "Done. Refresh ComfyUI, open Workflows, pick H3-Character-Swap."
