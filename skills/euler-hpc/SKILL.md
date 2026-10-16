---
name: euler-hpc
description: >-
  Run work on ETH Zurich's Euler cluster efficiently: Slurm batch jobs, job arrays, GPU jobs, interactive
  allocations and the submit → monitor → logs loop, which session submitted which job, installing software and
  Python environments, containers, moving data in and out. Trigger on "run this on the cluster", "submit a job",
  "sbatch this", "run on a GPU", "run this for every sample", "hold a node", "is my job done?", "why did my job
  fail?", "which session started this job?", "install X on Euler", "copy this to/from Euler". The rules for every
  session (node, allocation, storage, snapshots, cancelling) come from this plugin's session-start context.
---

# Euler HPC

How to run work on Euler. The session-start context holds the rules for every session; if it is missing, read
`${CLAUDE_PLUGIN_ROOT}/hooks/session_context.md`. Docs paths below are relative to https://docs.hpc.ethz.ch; read
the page when you need more than the summary here.

Work that doesn't fit this session's allocation takes one of three shapes: one **batch job**, a **job array** for
many near-identical items, or an **interactive allocation** for several short commands that need more than this
session holds, such as debugging GPU code from a CPU session; a single run, or anything long, is a batch job. Each
has a section below. Reference: `/batchsystem/slurm/`.

## Writing the job script

Start from `assets/euler_job.sh`. Euler-specific Slurm rules:

- **No `--partition`.** Slurm auto-selects it from your `--time` / `--gpus` / `--gres`.
- **`--time`** defaults to **1 h** if unset, and it *also selects the time-windowed partition* — so right-size
  it. Over-asking pushes you to a longer-queue partition (more wait); multi-day is allowed but the max is
  account-dependent.
- **Memory: `--mem-per-cpu` only.** Euler rejects `--mem`.
- **Threads:** one multithreaded process = `--ntasks=1 --cpus-per-task=N`. Euler sets `OMP_NUM_THREADS=N` only
  if the submitting shell has none, and a session inside a job has its own job's; so set
  `export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-1}`, or OpenMP/MKL/numba use the wrong count and oversubscribe.
- **Logs:** if the project says where batch logs go, use that. Otherwise `--output=logs/%x-%j.out`, and create
  `logs/` **at submit time** (`mkdir -p logs && sbatch …`). If the `--output` directory is missing the job **fails
  to launch and requeues in a loop** (no log, confusing PENDING/FAILED flapping) — `#SBATCH` lines are parsed
  before the script body, so a `mkdir` inside the script can't save it. The path resolves against the **submit
  directory**, not the script, so pass it absolutely (`sbatch --output="$LOGDIR/%x-%j.out" …`) whenever you
  submit from more than one place, or from a directory that may be deleted.
- **Paths:** the job starts in the submit directory. Pass anything that differs per machine or checkout at submit
  (`sbatch --export=ALL,DATA="$data" job.sh`, or as script arguments) instead of hardcoding it in the script.
  Slurm runs a copy of the script from its spool directory, so `$BASH_SOURCE` and `$0` don't point into your
  checkout.
- **Shared storage only.** The job runs on another node, so its working directory, inputs and log directory must
  be on home, project, work or scratch storage — never under `$TMPDIR` or `/tmp`, which are node-local (an
  agent's own scratch directory often is) — and must still exist when the job runs: don't remove a git worktree
  while jobs submitted from it are queued or running.
- **Env runner:** run work the way the project runs its scripts (`pixi run`, `uv run`, or what its `AGENTS.md`
  or workflow skill says). `sbatch` hands the job your submit environment, `PATH` included, but the job shell
  doesn't source `~/.bashrc`. If the manager isn't on `PATH` where you submit, or you pass `--export=NONE`, use its
  absolute path (`command -v pixi`).
- **In-job internet:** add `module load eth_proxy` only if the job downloads or talks to an online service.
  Python `aiohttp` ignores the proxy unless its session is created with `trust_env=True`.
- **Heavy many-small-file I/O:** stage to node-local **`$TMPDIR`** (request size with `--tmp=<size>`), compute
  there, copy results back — don't hammer shared storage.

Minimal CPU job:

```bash
#!/bin/bash
#SBATCH --job-name=myjob
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem-per-cpu=4g
#SBATCH --time=04:00:00
#SBATCH --output=logs/%x-%j.out
set -euo pipefail
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-1}
pixi run python scripts/run_me.py     # runs in the submit directory
```

## GPU jobs

- **Request a specific GPU model**, not a bare `--gpus=1`: queues differ by model, and which models you can get
  depends on your shareholder group. From the user's plugin settings: default model "${user_config.gpu_model}",
  fallback "${user_config.gpu_fallback}". If one is empty or an unfilled placeholder, or the work needs more VRAM
  than it has, ask the user; they can save defaults with `/plugin configure euler-hpc@quadbio`. Use the short
  model names listed below: the full name `sinfo` shows (`nvidia_geforce_rtx_4090`) is accepted but silently
  becomes a request for any GPU.

  ```bash
  #SBATCH --gpus=<model>:1
  #SBATCH --gres=gpumem:24g      # VRAM floor — ALWAYS give a unit
  ```

- **`--gres=gpumem` units are mandatory.** `24g`/`24G` = 24 GiB. A **bare number is bytes** (`gpumem:24000` ≈
  24 KB → effectively no floor, and you silently land on a small card).
- **Models / VRAM** (docs: https://docs.hpc.ethz.ch/hardware/gpu_nodes/): `rtx_2080` 11g · `rtx_3090` /
  `rtx_4090` / `rtx_6000` / `nvidia_titan_rtx` 24g · `a100` 40g · `a100_80gb` 80g · `pro_6000` 96g. Slurm routes
  to the partition that has the model you asked for.
- **Which queue is shorter:** submit to the default model; if the job is still pending after about 5 minutes,
  cancel it and resubmit on the fallback. `sbatch --test-only` and `squeue --start` can't tell: they assume
  running jobs use their whole time limit, and `--test-only` ignores jobs queued ahead.
- **Account:** omit `--account`; Slurm uses your default share. If `my_share_info` lists several, ask the user
  which (they can set it once with `SBATCH_ACCOUNT`, `SALLOC_ACCOUNT` and `SLURM_ACCOUNT`).
- **Etiquette:** right-size model / `gpumem` / `--time`; don't hold an interactive GPU idle; `sbatch` long runs
  instead of sitting in an `srun --pty` GPU shell.

## Submit & monitor

```bash
mkdir -p logs
JOBID=$(sbatch --parsable job.sh)     # --parsable → just the numeric id, easy to capture
echo "submitted $JOBID"
```

- **Name jobs for this session**, e.g. after its task or worktree (`-J <task>-train`): other sessions share your
  user, and duplicate checks and lookups go by name.
- **Avoid duplicates:** before submitting, `squeue --me --name=<jobname>` — if one is already `PD`/`R`, don't
  resubmit.
- **Which session submitted what:** `euler-jobs` reads a job's session from the environment Slurm stores with it,
  so keep `--export` at its default (add variables as `--export=ALL,VAR=…`). `euler-jobs --mine` lists this
  session's jobs, `euler-jobs` all sessions'; `euler-jobs --summary` counts this session's by partition since it
  started, as a Markdown table for a report.
- **Chain steps:** `sbatch -d afterok:"$JOBID" next.sh` starts only after that job succeeded.
- **Poll, never block.** Do **not** use `tail -f` or `watch` — they hang a tool call until timeout. Take
  snapshots instead:

  ```bash
  euler-jobs --mine                 # this session's jobs; `myjobs -j "$JOBID"` for one job's details
  sacct -j "$JOBID" --format=JobID,State,Elapsed,MaxRSS,ReqMem,ExitCode
  sstat -j "$JOBID"                 # live usage of a RUNNING job
  tail -n 40 logs/<jobname>-"$JOBID".out
  ```

  Cadence: ~30–60 s for short jobs, a few minutes for long ones. Stop when `sacct` `State` leaves
  `PENDING`/`RUNNING`. Cancel with `scancel "$JOBID"`.
- **Check early, unasked:** once the expensive step should have started, read the log for progress and warnings
  (OOM, NCCL) and check GPU use. A smoke test on one GPU doesn't cover a run on several.
- **Right-size the next run:** compare `MaxRSS` and `Elapsed` with what you asked for;
  `get_inefficient_jobs --for-last-hours 24` lists your jobs that wasted CPU, RAM or GPU.

## When a job fails — symptom → cause → fix

Read the **whole** log and the `sacct` row before concluding (a job leaving the queue is not the same as
success). `MaxRSS` is in KB unless suffixed.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `FAILED`, no `.out`, flaps to `PENDING` | `logs/` dir missing at launch | `mkdir -p logs` before `sbatch` |
| `pixi: command not found` / `uv: …` | not on `PATH` at submit, or `--export=NONE` | absolute path to `pixi`/`uv` |
| `No such file`, or outputs in the wrong place | job ran in an unexpected directory, or it was removed | submit from the right directory; pass paths at submit |
| `OUT_OF_MEMORY`, `MaxRSS` ≈ `ReqMem` | system RAM | raise `--mem-per-cpu` |
| `CUDA out of memory` in log | GPU VRAM | raise `--gres=gpumem` (or smaller batch / bigger card) |
| `TIMEOUT` | walltime too low | raise `--time` |
| network hang/timeout on download | no `eth_proxy` | `module load eth_proxy` |
| `CANCELLED` right at start, no output | job startup took over 120 s, e.g. a slow `~/.bashrc` (conda init on work storage) | slim the shell startup (`/news/2026-01-12-slurm-upgrade/`) |
| GPU job never schedules | model/VRAM your share can't provide | another model; check `my_share_info` |

## Job arrays (parallel, one task per item)

For embarrassingly-parallel work — one task per sample / week / parameter — a Slurm **array** runs N
near-identical tasks from a single script, each with a distinct `$SLURM_ARRAY_TASK_ID`. This is the
no-dependency, built-in way; for complex multi-parameter sweeps, if the project already has a sweep launcher
(e.g. Hydra's submitit launcher), offer it rather than assuming.

```bash
#SBATCH --array=0-9              # 10 tasks (indices 0..9). Also a list "0,3,5" or step "0-18:2"
#SBATCH --array=0-99%10          # cap: at most 10 tasks run at once
#SBATCH --output=logs/%x-%A_%a.out   # %A=array job id, %a=task index — NOT %j (which would collide)
```

Map the index to the work item inside the script:

```bash
SAMPLES=(week2 week3 week4 week6)
S="${SAMPLES[$SLURM_ARRAY_TASK_ID]}"
pixi run python scripts/process.py --sample "$S"
# or pick the Nth line of a manifest:
# LINE=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" inputs.txt)
```

All tasks share `$SLURM_ARRAY_JOB_ID`. The `%N` cap keeps tasks beyond it `PENDING` with reason
`JobArrayTaskLimit`. Before submitting a large array, ask the user for the cap: their other sessions' jobs queue
behind it on the same fair-share, and only they know what else is running. Monitor/cancel by the array
id: `squeue -j <A>`, `sacct -j <A>`; `scancel <A>` kills the whole array, `scancel <A>_<a>` one task. Use `%A_%a`
in `--output` so each task writes its own log (and still `mkdir -p logs` first).

## Interactive allocation

A person at a terminal outside a job gets a live shell on a compute node with:

```bash
# CPU
srun --ntasks=1 --cpus-per-task=4 --mem-per-cpu=4g --time=02:00:00 --pty bash
# GPU (pick a model as above; keep --time short; exit when done)
srun --gpus=<model>:1 --gres=gpumem:24g --cpus-per-task=4 --mem-per-cpu=8g \
     --time=01:00:00 --pty bash
```

Release it when you stop iterating — don't sit on a GPU.

An agent, driving over separate shell calls where `cd` and env don't persist, holds the node once and runs each
command into it with `euler-step`, which gives the command the whole allocation:

```bash
salloc --no-shell --cpus-per-task=4 --mem-per-cpu=2g --time=01:00:00 -J <task>-explore
euler-step <task>-explore python scripts/probe.py    # ~1–2 s overhead, in this directory
scancel "$(squeue --me --name=<task>-explore -h -o %i)"
```

A step lasts as long as its command: start a long one in the background and poll it, as for jobs.

## When this session runs inside a job

If `$SLURM_JOB_ID` is set (the session-start context says so), this session is itself a Slurm job. `sbatch` and
`salloc` create new jobs as usual. A plain `srun` does **not**: it runs as a step of this session's job, on this
node and from its resources. For a new allocation, use `salloc` or `sbatch`.

## Software

- **Modules:** if `module avail` doesn't list a package, `module spider <name>` shows what to load first. The
  newest stack can be Spack-only, without modules. (`/software/environment-modules/`, `/software/software-stack/`)
  Rendering PDFs to images, for example: `module spider poppler` (`pdftoppm`) or `ghostscript`.
- **Python:** use the project's environment manager (pixi, uv). Without one, a venv on a stack's `python` module.
  Before Python 3.13, `ThreadPool()` ignores the job's CPU limit: pass `processes=len(os.sched_getaffinity(0))`.
  (`/software/proglang/python/`)
- **Conda:** avoid. If unavoidable, never on work storage (Lustre handles many small files badly), and mind home's
  file quota. (`/software/package-managers/conda/`)
- **Containers:** Apptainer needs access (`get-access`); point `APPTAINER_CACHEDIR` at scratch; images can't be
  built on Euler; `--nv` for GPUs. (`/software/apptainer/`)

## Moving data

- `rsync` to or from `euler.ethz.ch` (login nodes); tar many small files first. `rclone` for Polybox on login
  nodes (`/connections/polybox/`); ask support before terabytes.
- Globus for large transfers (`/services/globus/`), from the shell with `globus-cli` (`uv tool install
  globus-cli`; on a compute node, `module load eth_proxy` first):
  - Euler's collections are `ETH Zurich#Euler Project`, `ETH Zurich#Euler Work` and `ETH Zurich#Euler Scratch`;
    `globus api transfer GET /endpoint_search -Q filter_fulltext=Euler` shows the current set. Paths are relative
    to the filesystem the collection's description names: `/cluster/project/<group>/x` is `/<group>/x` in Project.
  - Logging in needs the human: run `globus login --no-local-server` where they can type, e.g. a tmux window;
    they open the URL and paste the code there themselves. Each mapped collection also needs one
    `globus session consent` for its `data_access` scope; one consent can bundle several collections.
  - `globus endpoint search` and `globus ls` can take minutes; `globus api transfer GET
    /operation/endpoint/<id>/ls -Q path=<path>` answers in under a minute.
  - `globus transfer --batch` takes one source and destination pair per line; `--dry-run` prints the task
    without submitting it. The docs recommend keeping checksum verification, encrypting up to a few TB, and
    failing on quota errors when uploading.
- A directory named `nobackup` is left out of backups. Don't process data in batch jobs directly from external
  storage. (`/hardware/storage/`)

## What the human runs

- **euler-tunnel:** a batch job the human starts from their machine (`euler-tunnel start --time=…`) to reach a
  compute node by ssh or VS Code; `euler-tunnel status` shows it. A session inside it ends with that job.
  (`/connections/euler-tunnel/`)
- **JupyterHub** sessions are batch jobs too: at most 24 h, and closing the browser doesn't stop them.
  (`/services/jupyterhub/`)

## Quick reference

- No `--partition`; `--mem-per-cpu` (never `--mem`); `--time` picks the partition (default 1 h).
- GPU: `--gpus=<model>:1` (default "${user_config.gpu_model}"; fallback "${user_config.gpu_fallback}" if still
  pending after ~5 min) + `--gres=gpumem:24g` (unit required); omit `--account`.
- `mkdir -p logs && JOBID=$(sbatch --parsable job.sh)`; poll `euler-jobs --mine`/`sacct`/`sstat`, never
  `tail -f`. Cancel only this session's jobs.
- Job names carry the task (`-J <task>-…`); paths come in at submit, not hardcoded; run scripts the project's way.
- Parallel per-item work: `--array=0-N%K` (ask the user for `K`) + `$SLURM_ARRAY_TASK_ID` +
  `--output=…%A_%a.out` (or the project's sweep launcher).
- Iterating on a node: `salloc --no-shell -J <task>-…`, then `euler-step <task>-… <command>`; `scancel` when done.
- Inside a job: plain `srun` is a step of this job; new allocations via `salloc`/`sbatch`.
- Template: `assets/euler_job.sh`.
