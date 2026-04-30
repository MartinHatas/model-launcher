#!/usr/bin/env bash
# Bench harness — sweeps llama-bench across ctx depths for a (model, profile)
# and captures peak wired memory. Writes TSV under bench/<model>/<profile>/<date>.tsv.
#
# Usage:
#   ./bench.sh                              # fzf-pick model + profile, run sweep
#   ./bench.sh --all                        # sweep every (model, profile) combo
#   ./bench.sh path/to/model.gguf conf      # non-interactive
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/models"
BENCH_DIR="$SCRIPT_DIR/bench"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

die() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }

command -v llama-bench &>/dev/null || die "llama-bench not found in PATH"
command -v fzf         &>/dev/null || die "fzf required for interactive mode (brew install fzf)"

# Prompt-processing size for PP test (bigger = more stable tok/s measurement)
PP_TOKENS=2048
# Generation size for TG test
TG_TOKENS=128
# Repetitions per point (llama-bench default 5, we use 3 for speed)
REPS=3
# Depth points to sweep (skipped if > profile CTX_SIZE)
DEPTHS=(0 8192 32768 65536 131072)

# ── Collect (model, conf) pairs ───────────────────────────────────────────────
PAIRS=()
while IFS= read -r gguf; do
    dir="$(dirname "$gguf")"
    while IFS= read -r conf; do
        PAIRS+=("$gguf"$'\t'"$conf")
    done < <(find "$dir" -maxdepth 1 -name '*.conf' -type f | sort)
done < <(find "$MODEL_DIR" -type f \( -name '*.gguf' -o -name '*.GGUF' \) | sort)

[[ ${#PAIRS[@]} -gt 0 ]] || die "No (model, profile) pairs found under $MODEL_DIR"

# ── Select targets ────────────────────────────────────────────────────────────
TARGETS=()
if [[ "${1:-}" == "--all" ]]; then
    TARGETS=("${PAIRS[@]}")
elif [[ $# -ge 2 ]]; then
    TARGETS=("$1"$'\t'"$2")
else
    picker=""
    for p in "${PAIRS[@]}"; do
        gguf="${p%%$'\t'*}"; conf="${p##*$'\t'}"
        rel_m="${gguf#"$MODEL_DIR/"}"
        rel_c="$(basename "$conf" .conf)"
        picker+="$p"$'\t'"$rel_m  [$rel_c]"$'\n'
    done
    selection=$(
        echo -n "$picker" \
        | fzf --multi --no-sort --delimiter=$'\t' --with-nth=3 \
              --height=~100% --layout=reverse-list \
              --prompt="  Bench targets (Tab=multi) > " \
              --pointer="▶" --marker="●" \
              --color='pointer:green,prompt:blue,marker:green' \
              --header="Tab=select multiple · Enter=confirm"
    ) || die "No target selected"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        TARGETS+=("${line%$'\t'*}")
    done <<< "$selection"
fi

# ── Run one bench per target ──────────────────────────────────────────────────
DATE_STAMP="$(date +%Y%m%d-%H%M%S)"

for pair in "${TARGETS[@]}"; do
    gguf="${pair%%$'\t'*}"
    conf="${pair##*$'\t'}"
    model_rel="$(basename "$(dirname "$gguf")")"
    profile="$(basename "$conf" .conf)"

    # shellcheck source=/dev/null
    (
        set -a; source "$conf"; set +a
        out_dir="$BENCH_DIR/$model_rel/$profile"
        mkdir -p "$out_dir"
        out_tsv="$out_dir/$DATE_STAMP.tsv"

        echo ""
        echo -e "  ${BOLD}$model_rel${NC} / ${DIM}$profile${NC}"
        echo "  ────────────────────────────────"
        echo -e "  ${DIM}ctx=${CTX_SIZE} ubatch=${UBATCH_SIZE} kv=${CACHE_TYPE_K}/${CACHE_TYPE_V} ncmoe=${N_CPU_MOE:-0}${NC}"

        # Filter depths that exceed this profile's ctx
        depths=()
        for d in "${DEPTHS[@]}"; do
            [[ "$d" -le "$CTX_SIZE" ]] && depths+=("$d")
        done
        depths_csv="$(IFS=,; echo "${depths[*]}")"

        # Capture peak memory while bench runs (best-effort on macOS)
        mem_log="$out_dir/$DATE_STAMP.memory.log"
        (
            while true; do
                vm_stat 2>/dev/null | awk '/Pages wired down/ {gsub(/\./,"",$4); print $4*16384}' >> "$mem_log"
                sleep 2
            done
        ) &
        MEM_PID=$!
        trap 'kill $MEM_PID 2>/dev/null || true' EXIT INT TERM

        # Run llama-bench. Duplicated flags like -ctk/-ctv/-b/-ub accept scalar values;
        # -d takes comma-separated depth list; -p and -n are the workload sizes.
        llama-bench \
            -m "$gguf" \
            -p "$PP_TOKENS" \
            -n "$TG_TOKENS" \
            -d "$depths_csv" \
            -b "$BATCH_SIZE" \
            -ub "$UBATCH_SIZE" \
            -ctk "$CACHE_TYPE_K" \
            -ctv "$CACHE_TYPE_V" \
            -ngl "$GPU_LAYERS" \
            -t "$THREADS" \
            -ncmoe "${N_CPU_MOE:-0}" \
            -fa 1 \
            -r "$REPS" \
            --progress \
            -o csv \
            2> "$out_dir/$DATE_STAMP.stderr.log" \
            | tee "$out_tsv.csv"

        kill $MEM_PID 2>/dev/null || true
        trap - EXIT INT TERM

        # Convert CSV → TSV and annotate with profile metadata
        {
            printf 'profile\t%s\n' "$profile"
            printf 'model\t%s\n' "$model_rel"
            printf 'date\t%s\n' "$DATE_STAMP"
            printf 'ctx_size\t%s\n' "$CTX_SIZE"
            printf 'batch\t%s\n' "$BATCH_SIZE"
            printf 'ubatch\t%s\n' "$UBATCH_SIZE"
            printf 'kv_k\t%s\n' "$CACHE_TYPE_K"
            printf 'kv_v\t%s\n' "$CACHE_TYPE_V"
            printf 'n_cpu_moe\t%s\n' "${N_CPU_MOE:-0}"
            printf 'threads\t%s\n' "$THREADS"
            if [[ -s "$mem_log" ]]; then
                peak=$(sort -n "$mem_log" | tail -1)
                peak_gb=$(awk "BEGIN{printf \"%.2f\", $peak/1073741824}")
                printf 'peak_wired_bytes\t%s\n' "$peak"
                printf 'peak_wired_gb\t%s\n' "$peak_gb"
            fi
            printf '\n--- llama-bench csv ---\n'
            cat "$out_tsv.csv"
        } > "$out_tsv"
        rm -f "$out_tsv.csv"

        echo -e "  ${GREEN}▶${NC} wrote $out_tsv"
    )
done

echo ""
echo -e "  ${BOLD}All benches complete.${NC}"
echo -e "  Results under: ${BENCH_DIR}/"
