# model-launcher

Interactive [`llama-server`](https://github.com/ggml-org/llama.cpp) launcher for local GGUF models. Pick a model, pick a tuned profile, tweak anything, and it starts the server — then prints ready-to-paste connection commands for your coding agent.

Tuned for a MacBook M3 Pro (36 GB), but the profiles are just text files you can edit.

## Requirements

- [`llama.cpp`](https://github.com/ggml-org/llama.cpp) — `llama-server` (and `llama-bench` for benchmarking) on your `PATH`
- [`fzf`](https://github.com/junegunn/fzf) — `brew install fzf`
- `python3` — used to write the OpenCode / Pi agent configs

## Layout

```
models/<org>/<model>/
  ├── *.gguf          # the model weights (git-ignored)
  └── *.conf          # one or more tuned profiles for that model
launch.sh             # interactive launcher
bench.sh              # throughput / memory benchmark sweep
```

Drop a `.gguf` anywhere under `models/` and it shows up in the picker. Profiles are optional — without one, built-in defaults are used.

## Getting the models

**The `.gguf` weight files are not in this repo** (they're git-ignored — too large). You download them yourself and place them into the matching folder. Only the `.conf` profiles are tracked.

The profiles here target Unsloth's Qwen3.6 GGUFs. Grab the quant you want from Hugging Face, e.g.:

```bash
hf download unsloth/Qwen3.6-35B-A3B-MTP-GGUF \
  --include "*UD-Q4_K_XL*" \
  --local-dir models/unsloth/Qwen3.6-35B-A3B-MTP-Q4_K_XL
```

The folder name is up to you — the launcher reads whatever `.gguf` it finds and the `.conf` files sitting next to it. Make sure the quant you download matches what the profile expects (e.g. a `*-MTP-*` GGUF for the MTP profiles).

## Usage

```bash
./launch.sh
```

1. **Pick a model** — fzf list of every `.gguf` under `models/` (with size and profile count).
2. **Pick a profile** — if the model's folder has `.conf` files (skipped if there's only one or none).
3. **Override** — optionally tweak any parameter (context size, temperature, KV cache type, etc.) before launch.
4. The server starts on `http://localhost:8001`, and connection snippets for **Claude Code, Qwen Code, OpenCode, Codex, and Pi** are printed.

## Profiles

A profile is a plain shell file of `KEY=value` lines, sourced at launch. Naming convention used here:

| Profile | When to use |
|---|---|
| `thinking.conf` | Reasoning on, coding-tuned sampling, ≤65k context |
| `non-thinking.conf` | Reasoning off, faster, ≤65k context |
| `*-long-ctx.conf` | Same, but 131k context (more KV cache / CPU-MoE offload) |

Each file is commented with the reasoning behind its values. Copy one, edit, and it becomes a new selectable profile.

### MTP (Multi-Token Prediction)

MTP-GGUF models (e.g. `*-MTP-*`) carry an embedded draft head for self-speculative decoding — **~1.4–2x faster generation, no accuracy loss**. Their profiles set:

```sh
MTP=on
SPEC_DRAFT_N_MAX=2   # draft tokens per step; 2 is the sweet spot, try 1–6
```

The launcher forces a single slot (`-np 1`) when MTP is on, since multi-slot isn't supported with it yet.

## Benchmarking

Sweep throughput and peak memory across context depths for any (model, profile):

```bash
./bench.sh            # fzf-pick targets
./bench.sh --all      # every model + profile
```

Results land as TSV under `bench/<model>/<profile>/`. Use this to confirm a profile fits in memory and to tune `N_CPU_MOE` / context size.
