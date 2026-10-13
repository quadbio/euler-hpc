# Sizing jobs for cost and per-user caps

Checked on Euler in October 2026 from one shareholder account. Re-check the numbers with the commands given before
relying on them; caps in particular change without notice.

## What Slurm bills

`scontrol show partition` gives every GPU partition (and bigmem) the same weights:
`TRESBillingWeights=CPU=0.00782,MEM=4.24M,GRES/gpu=0.0625`. There is no per-model GPU weight, so a job's `billing`
scales with **requested RAM**; the GPU model and the CPU count barely enter. Observed `billing` (sacct `AllocTRES`):

| GPU | CPUs | RAM requested | billing |
| --- | --- | --- | --- |
| A100 80 GB | 4 | 64 GB | 277,872 |
| Quadro RTX 6000 | 4 | 64 GB | 277,872 |
| RTX 4090 | 4 | 32 GB | 138,936 |
| A100 80 GB | 8 | 192 GB | 833,617 |

Whether ETH's shareholder invoicing weights GPU models outside Slurm is not verified. Check a job with
`sacct -j <id> -X --format=JobID,AllocTRES%80`.

## Rules

1. **RAM from measurement:** about 1.3 × `MaxRSS` of an earlier run of the same job type
   (`sacct -j <id> --format=JobID,MaxRSS,Elapsed`; `MaxRSS` is on the `.batch` step, blank with `-X`). One training
   run peaked at 15 GB but asked for 128 GB, and was billed eight times what it needed.
2. **New job type: smoke-test first** (a few hundred steps, short `--time`), read `MaxRSS`, GPU memory and time per
   step, then size the real run.
3. **CPUs 4–8.** RAM comes per CPU, so CPUs × `--mem-per-cpu` is what you pay for.
4. **`--time` realistic, ideally ≤ 4 h:** shorter tiers start sooner and have larger per-user caps.
5. **GPU architecture:** bf16 and flash-attention need Ampere or newer (RTX 3090, RTX 4090, A100). TITAN RTX,
   Quadro RTX 6000 and RTX 2080 Ti are Turing: fp32/fp16 only. Ask for an 80 GB A100 only after a smaller batch,
   chunking or gradient checkpointing on a 24 GB card has failed; A100s have the longest queues and the smallest
   per-user caps. The RTX Pro 6000 (Blackwell, `cuda13pr` partitions) needs a torch build for CUDA ≥ 12.8.
6. **Verify the card you got:** `sacct -j <id> -X --format=JobID,Partition,ReqTRES%90,NodeList` must show
   `gres/gpu:<model>=1`, and print `nvidia-smi --query-gpu=name,memory.total --format=csv` at the top of the log.
7. A pending job that is too big can shrink in place: `scontrol update JobId=<id> MinMemoryCPU=<MB>`.

## Per-user caps

Each shareholder account caps what one user may run at once per partition and time tier (QOS `maxtrespu`: GPUs,
CPUs, RAM). The caps are shared by all of the user's sessions, so a sweep that fills them stalls everyone's other
jobs, and over-requested RAM costs twice: billed, and holding the user's queue at `PENDING (QOSMaxMemoryPerUser)`.

`euler-caps` (this plugin's `bin/`) prints the current caps next to what the user's jobs use now, in about a
second: `euler-caps` on Euler, `essh 'bash -s' < "$(command -v euler-caps)"` from another machine, `--all` to add
bigmem, hpc and ultramem. Run it before a sweep or array and whenever jobs pend with a `QOSMax*` reason. Never copy
the numbers into notes or settings: read them live.

## Traps seen in practice

- **W&B on a compute node:** `eth_proxy` puts `api.wandb.ai` in `no_proxy`, so online logging fails even with the
  proxy loaded. Use `WANDB_MODE=offline` in the job and `wandb sync` from a login node afterwards.
- **uv venvs lack `setuptools`;** triton (flash-attention) then fails at import with a misleading
  "rotary_emb is not installed". `uv pip install setuptools`.
- **Caches:** besides `HF_HOME` and the package managers, point `TRITON_CACHE_DIR`, `TORCH_HOME`, `NUMBA_CACHE_DIR`
  and `MPLCONFIGDIR` at scratch. Scratch is purged, so model weights may need fetching again (with `eth_proxy`).
