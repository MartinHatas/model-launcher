#!/usr/bin/env bash
# Interactive llama-server launcher.
# Scans models/, lets you pick one, shows/overrides parameters, starts the server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/models"

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

die() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────
command -v fzf          &>/dev/null || die "fzf is required (brew install fzf)"
command -v llama-server &>/dev/null || die "llama-server not found in PATH"

# ── Hardcoded fallback defaults ───────────────────────────────────────────────
# Applied when a model directory has no profiles (.conf files).
# Values: Unsloth Qwen3.5 coding recommendations for M3 Pro 36GB.
CTX_SIZE=131072
N_PREDICT=16384
TEMP=0.6
TOP_P=0.95
TOP_K=20
MIN_P=0.0
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0
BATCH_SIZE=4096
UBATCH_SIZE=4096
GPU_LAYERS=99
THREADS=6
N_CPU_MOE=0
PRESENCE_PENALTY=0.0
REPEAT_PENALTY=1.0
REASONING=off
REASONING_BUDGET=0
CHAT_TEMPLATE_KWARGS=""
N_PARALLEL=1
PORT=8001

# ── Scan models ───────────────────────────────────────────────────────────────
MODEL_PATHS=()
while IFS= read -r f; do
    MODEL_PATHS+=("$f")
done < <(find "$MODEL_DIR" -type f \( -name '*.gguf' -o -name '*.GGUF' \) | sort)
[[ ${#MODEL_PATHS[@]} -gt 0 ]] || die "No .gguf files found under $MODEL_DIR"

# Build display lines: "relative/path  SizeG  (profile count)"
PICKER_LINES=()
for path in "${MODEL_PATHS[@]}"; do
    rel="${path#"$MODEL_DIR/"}"
    size_bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
    size_gb=$(awk "BEGIN{printf \"%.0f\", $size_bytes / 1073741824}")
    conf_dir="$(dirname "$path")"
    conf_count=$(find "$conf_dir" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | wc -l | tr -d ' ')
    indicator=""
    [[ "$conf_count" -gt 0 ]] && indicator=" ($conf_count)"
    PICKER_LINES+=("$(printf '%s  %sG%s' "$rel" "$size_gb" "$indicator")")
done

# ── Model picker ──────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}llama-server launcher${NC}"
echo "  ────────────────────────────────"

selected_idx=$(
    for i in "${!PICKER_LINES[@]}"; do
        printf '%d\t%s\n' "$i" "${PICKER_LINES[$i]}"
    done \
    | fzf --no-sort \
          --delimiter=$'\t' \
          --with-nth=2.. \
          --height=~100% \
          --layout=reverse-list \
          --prompt="  Model > " \
          --pointer="▶" \
          --header="↑↓ navigate · Enter select" \
          --color='pointer:green,prompt:blue' \
    | cut -f1
)
[[ -n "$selected_idx" ]] || die "No model selected"

MODEL_PATH="${MODEL_PATHS[$selected_idx]}"
MODEL_NAME="$(basename "$MODEL_PATH" .gguf)"
echo -e "  ${GREEN}▶${NC} $(basename "$MODEL_PATH")"

# ── Load profile ─────────────────────────────────────────────────────────────
CONF_DIR="$(dirname "$MODEL_PATH")"
CONF_FILES=()
while IFS= read -r f; do
    CONF_FILES+=("$f")
done < <(find "$CONF_DIR" -maxdepth 1 -name '*.conf' -type f | sort)

if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}no profiles found — using built-in fallbacks${NC}"
elif [[ ${#CONF_FILES[@]} -eq 1 ]]; then
    # shellcheck source=/dev/null
    source "${CONF_FILES[0]}"
    echo -e "  ${DIM}profile: $(basename "${CONF_FILES[0]}" .conf)${NC}"
else
    PROFILE_LINES=()
    for f in "${CONF_FILES[@]}"; do
        PROFILE_LINES+=("$(basename "$f" .conf)")
    done

    selected_profile=$(
        for i in "${!PROFILE_LINES[@]}"; do
            printf '%d\t%s\n' "$i" "${PROFILE_LINES[$i]}"
        done \
        | fzf --no-sort \
              --delimiter=$'\t' \
              --with-nth=2.. \
              --height=~100% \
              --layout=reverse-list \
              --prompt="  Profile > " \
              --pointer="▶" \
              --header="↑↓ navigate · Enter select" \
              --color='pointer:green,prompt:blue' \
        | cut -f1
    )
    [[ -n "$selected_profile" ]] || die "No profile selected"

    # shellcheck source=/dev/null
    source "${CONF_FILES[$selected_profile]}"
    echo -e "  ${GREEN}▶${NC} ${PROFILE_LINES[$selected_profile]}"
fi

# ── Parameter list (order matters for display) ────────────────────────────────
# Parallel arrays: variable names, display labels, current values
PARAM_NAMES=(CTX_SIZE N_PREDICT TEMP TOP_P TOP_K MIN_P PRESENCE_PENALTY REPEAT_PENALTY CACHE_TYPE_K CACHE_TYPE_V BATCH_SIZE UBATCH_SIZE GPU_LAYERS THREADS N_CPU_MOE REASONING REASONING_BUDGET CHAT_TEMPLATE_KWARGS N_PARALLEL PORT)
PARAM_LABELS=("Context size" "Max output" "Temperature" "Top-P" "Top-K" "Min-P" "Presence penalty" "Repeat penalty" "KV cache K" "KV cache V" "Batch size" "Ubatch size" "GPU layers" "Threads" "CPU-MoE layers" "Reasoning" "Reasoning budget" "Chat tmpl kwargs" "Parallel slots" "Port")

get_param() { eval echo "\$$1"; }

# ── Show parameter summary ────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Parameters${NC}"
echo "  ────────────────────────────────"
for i in "${!PARAM_NAMES[@]}"; do
    printf "  %-18s %s\n" "${PARAM_LABELS[$i]}" "$(get_param "${PARAM_NAMES[$i]}")"
done
echo ""

# ── Override prompt ───────────────────────────────────────────────────────────
read -rp "  Override parameters? (y/N): " override_answer
if [[ "$override_answer" =~ ^[Yy]$ ]]; then
    # fzf multi-select: show "Label  CurrentValue" lines
    override_input=""
    for i in "${!PARAM_NAMES[@]}"; do
        override_input+="$(printf '%d\t%-18s %s' "$i" "${PARAM_LABELS[$i]}" "$(get_param "${PARAM_NAMES[$i]}")")"$'\n'
    done

    selected_params=""
    selected_params=$(
        echo -n "$override_input" \
        | fzf --multi \
              --no-sort \
              --delimiter=$'\t' \
              --with-nth=2.. \
              --height=$(( ${#PARAM_NAMES[@]} + 4 )) \
              --layout=reverse-list \
              --prompt="  Select params (Tab to toggle) > " \
              --pointer="▶" \
              --marker="●" \
              --header="Tab select · Enter confirm" \
              --color='pointer:green,prompt:blue,marker:green'
    ) || true

    if [[ -n "$selected_params" ]]; then
        # Extract indices from fzf output (first tab-delimited field per line)
        indices=""
        while IFS= read -r line; do
            indices+="${line%%$'\t'*}"$'\n'
        done <<< "$selected_params"

        echo ""
        while IFS= read -r idx; do
            [[ -n "$idx" ]] || continue
            name="${PARAM_NAMES[$idx]}"
            label="${PARAM_LABELS[$idx]}"
            current="$(get_param "$name")"
            read -rp "  $label [$current]: " new_value </dev/tty
            if [[ -n "$new_value" ]]; then
                eval "$name=\"$new_value\""
            fi
        done <<< "$indices"

        # Reprint updated summary
        echo ""
        echo -e "  ${BOLD}Updated parameters${NC}"
        echo "  ────────────────────────────────"
        for i in "${!PARAM_NAMES[@]}"; do
            printf "  %-18s %s\n" "${PARAM_LABELS[$i]}" "$(get_param "${PARAM_NAMES[$i]}")"
        done
    fi
fi

# ── Derive reasoning budget from mode ─────────────────────────────────────────
if [[ "$REASONING" == "on" && "$REASONING_BUDGET" == "0" ]]; then
    REASONING_BUDGET="-1"
fi

# ── Write OpenCode provider config ───────────────────────────────────────────
OPENAI_BASE="http://localhost:$PORT/v1"
ANTHROPIC_BASE="http://localhost:$PORT"
OC_CONFIG="$HOME/.config/opencode/opencode.json"
mkdir -p "$(dirname "$OC_CONFIG")"
OC_BASE_URL="$OPENAI_BASE" OC_MODEL_KEY="$MODEL_NAME" \
OC_CTX="$CTX_SIZE" OC_OUT="$N_PREDICT" \
python3 <<'PY'
import json, os
path = os.path.expanduser("~/.config/opencode/opencode.json")
data = {"$schema": "https://opencode.ai/config.json"}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except Exception:
            pass
base_url  = os.environ["OC_BASE_URL"]
model_key = os.environ["OC_MODEL_KEY"]
ctx       = int(os.environ.get("OC_CTX", "131072"))
out       = int(os.environ.get("OC_OUT", "16384"))
prov = data.setdefault("provider", {}).setdefault("llama.cpp", {
    "npm": "@ai-sdk/openai-compatible",
    "name": "llama-server (local)",
    "options": {"baseURL": base_url},
    "models": {}
})
prov["options"]["baseURL"] = base_url
prov.setdefault("models", {})[model_key] = {
    "name": f"{model_key} (local)",
    "limit": {"context": ctx, "output": out}
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY

# ── Write Pi provider config ─────────────────────────────────────────────────
PI_CONFIG="$HOME/.pi/agent/models.json"
mkdir -p "$(dirname "$PI_CONFIG")"
PI_BASE_URL="$OPENAI_BASE" PI_MODEL_KEY="$MODEL_NAME" \
PI_CTX="$CTX_SIZE" PI_OUT="$N_PREDICT" \
python3 <<'PY'
import json, os
path = os.path.expanduser("~/.pi/agent/models.json")
data = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except Exception:
            pass
base_url  = os.environ["PI_BASE_URL"]
model_key = os.environ["PI_MODEL_KEY"]
ctx       = int(os.environ.get("PI_CTX", "131072"))
out       = int(os.environ.get("PI_OUT", "16384"))
prov = data.setdefault("providers", {}).setdefault("llama-cpp", {
    "api": "openai-completions",
    "apiKey": "sk-no-key",
    "compat": {
        "supportsDeveloperRole": False,
        "supportsReasoningEffort": False,
        "supportsUsageInStreaming": True,
        "maxTokensField": "max_tokens"
    },
    "models": []
})
prov["baseUrl"] = base_url
models = [m for m in prov.get("models", []) if m.get("id") != model_key]
models.append({
    "id": model_key, "name": f"{model_key} (local)",
    "reasoning": False, "input": ["text"],
    "contextWindow": ctx, "maxTokens": out,
    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
})
prov["models"] = models
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY

# ── Print agent connection info ───────────────────────────────────────────────
echo ""
echo "  ────────────────────────────────"
echo -e "  ${BOLD}Coding agent connection commands${NC}"
echo ""
echo -e "  ${BOLD}Claude Code${NC}"
echo "    export ANTHROPIC_BASE_URL=$ANTHROPIC_BASE"
echo "    export ANTHROPIC_API_KEY=sk-no-key"
echo "    export CLAUDE_CODE_ATTRIBUTION_HEADER=0"
echo "    claude --model $MODEL_NAME --dangerously-skip-permissions"
echo ""
echo -e "  ${BOLD}Qwen Code${NC}"
echo "    OPENAI_API_KEY=sk-no-key OPENAI_BASE_URL=$OPENAI_BASE OPENAI_MODEL=$MODEL_NAME qwen"
echo ""
echo -e "  ${BOLD}OpenCode${NC}  (config written to $OC_CONFIG)"
echo "    opencode --model llama.cpp/$MODEL_NAME"
echo ""
echo -e "  ${BOLD}Codex${NC}  (run via start.sh — needs tool-normalising proxy on :8002)"
echo "    ./start.sh  # then pick Codex"
echo ""
echo -e "  ${BOLD}Pi / shittycodingagent.ai${NC}  (config: ~/.pi/agent/models.json)"
echo "    pi --model llama-cpp/$MODEL_NAME"
echo ""
echo "  ────────────────────────────────"
echo -e "  ${GREEN}Starting llama-server...${NC}"
echo ""

# ── Build optional flags ─────────────────────────────────────────────────────
EXTRA_FLAGS=()
[[ -n "$CHAT_TEMPLATE_KWARGS" ]] && EXTRA_FLAGS+=(--chat-template-kwargs "$CHAT_TEMPLATE_KWARGS")
[[ "${N_CPU_MOE:-0}" -gt 0 ]] && EXTRA_FLAGS+=(--n-cpu-moe "$N_CPU_MOE")

# ── Launch ────────────────────────────────────────────────────────────────────
exec llama-server \
    --model "$MODEL_PATH" \
    --ctx-size "$CTX_SIZE" \
    --n-predict "$N_PREDICT" \
    -ngl "$GPU_LAYERS" \
    -t "$THREADS" \
    -b "$BATCH_SIZE" \
    -ub "$UBATCH_SIZE" \
    --temp "$TEMP" \
    --top-p "$TOP_P" \
    --top-k "$TOP_K" \
    --min-p "$MIN_P" \
    --presence-penalty "$PRESENCE_PENALTY" \
    --repeat-penalty "$REPEAT_PENALTY" \
    --cache-type-k "$CACHE_TYPE_K" \
    --cache-type-v "$CACHE_TYPE_V" \
    --flash-attn on \
    --kv-unified \
    --fit on \
    --port "$PORT" \
    --host 127.0.0.1 \
    -np "$N_PARALLEL" \
    --reasoning "$REASONING" \
    --reasoning-budget "$REASONING_BUDGET" \
    "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" \
    --jinja \
    --verbose \
    --log-timestamps \
    --perf
