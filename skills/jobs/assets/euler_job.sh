#!/bin/bash
# Euler Slurm job template (euler-hpc:jobs skill). Copy, fill <…>, then:  mkdir -p logs && sbatch --parsable job.sh
# Reference: https://docs.hpc.ethz.ch/batchsystem/slurm/

#SBATCH --job-name=<jobname>
#SBATCH --output=logs/%x-%j.out     # %x=name %j=id ; create logs/ BEFORE submitting (else requeue loop)
                                    # relative to the SUBMIT dir — override absolutely if that varies
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8           # cores for ONE multithreaded process
#SBATCH --mem-per-cpu=4g            # per CPU. Do NOT use --mem (rejected on Euler)
#SBATCH --time=04:00:00             # default 1h if unset; also selects the partition
##SBATCH --tmp=20g                  # node-local $TMPDIR, for heavy many-small-file I/O
# For N parallel per-item tasks, make this an array: add `--array=0-N%K` (K from the user), switch
# --output to `logs/%x-%A_%a.out`, and index work via $SLURM_ARRAY_TASK_ID (see skill).

# --- GPU (uncomment): a SPECIFIC model, the default configured for the skill unless the work needs more ---
##SBATCH --gpus=<gpu_model>:1
##SBATCH --gres=gpumem:24g          # VRAM floor — ALWAYS give a unit (a bare number = bytes!)

# --- Account: omit to use your default share. Only for another share: ---
##SBATCH --account=<share>

set -euo pipefail
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK:-1}   # else threaded libs grab all visible cores

# Internet only if the job needs it (compute nodes are firewalled):
# module load eth_proxy

# The job starts in the submit directory. Paths that differ per machine or checkout come in at submit,
# not hardcoded here:  sbatch --export=ALL,MAIN="$main" job.sh   (then use "$MAIN" below)

# Run it the way the project runs its scripts (from a git worktree, maybe --manifest-path "$MAIN/pixi.toml").
# The job inherits PATH from where you submit, but its shell doesn't source ~/.bashrc: if pixi/uv aren't
# on PATH at submit, use an absolute path.
pixi run python "scripts/<run_me>.py"
# uv run python "scripts/<run_me>.py"
