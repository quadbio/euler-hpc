# euler-hpc

A Claude Code plugin for running coding agents efficiently on [Euler](https://docs.hpc.ethz.ch/), ETH Zurich's
HPC cluster, from a session on Euler or on your own machine. It holds everything specific to the cluster, so other
plugins can stay cluster-agnostic: at session start it tells the agent where it runs, what its allocation holds,
your own setup and the rules for every session; its skills cover Slurm jobs and software, and moving data, summarising the docs and pointing to their
pages; and it links each job to the Claude session that submitted it.

| Part | What it does |
| --- | --- |
| `hooks/` | At session start. On Euler: node and allocation, your settings, always-on rules (nodes, inline vs Slurm, modules, storage, snapshots, cancelling). On a machine with the `euler-agents` ssh entry: that Euler is reached through `euler-ssh`, your settings, and where the rules are. |
| `skills/jobs/` | Slurm batch jobs, GPU jobs, arrays, interactive allocations, monitoring and failures; software and containers. An sbatch template. Loaded on demand. |
| `skills/data/` | Moving data in and out: rsync, Polybox, Globus from the shell. Loaded on demand. |
| `skills/connect/` | Reaching Euler from another machine: `euler-ssh` calls, setting up its connection once, restoring it. Loaded on demand. |
| `bin/euler-jobs` | `euler-jobs`: your Claude sessions on Euler, each with its tmux window, status, background commands, PRs and jobs; what needs you on top, and what the allocation they share uses now. For you and your agents. |
| `bin/euler-step` | `euler-step <job> <command>`: runs a command in an allocation you hold, with all of its CPUs, memory and GPUs. For agents iterating on a node. |
| `bin/euler-resume` | `euler-resume`: after your Euler job ends, reopens the Claude sessions that were still open, each with `claude --resume` in a window of the tmux session it ran in; you pick which. For you, in a new job. |
| `bin/euler-caps` | `euler-caps`: the per-user caps on running GPUs, CPUs and RAM in each of your group's QOS, next to what your jobs use against them now and how many pending jobs a cap holds. Before an array or sweep, and when jobs pend with a `QOSMax*` reason. |
| `bin/euler-ssh` | `euler-ssh 'command'`, `rsync -e euler-ssh`: commands and files for Euler from another machine, through one shared ssh connection, at most 6 at a time, each under a timeout on Euler. `euler-caps`, `euler-jobs` and `euler-step` use it by themselves there. |

Not affiliated with ETH Zurich; the [Euler docs](https://docs.hpc.ethz.ch/) are the reference.

## Use

Two ways, side by side:

- **On Euler**, next to the data: open an [euler-tunnel](https://docs.hpc.ethz.ch/connections/euler-tunnel/) onto a
  compute node and run Claude there, one session per `tmux` window, or from the desktop app as an SSH session to
  the tunnel (the tunnel offers no SFTP, so the app turns off file previews and its Changes pane). Each session
  starts inside an allocation, runs work inline while it fits, and goes through Slurm when it doesn't; it ends with
  the job (`euler-resume`).
- **From your machine**, with its files and tools: Claude runs on your laptop or a workstation, in a terminal or
  the desktop app, and uses Euler as a backend. Commands go through `euler-ssh` to a login node, work through
  Slurm, files through `rsync`; the code you edit is the local checkout, and Euler gets it by git or rsync. Nothing
  is held on Euler between jobs.

Ask in plain words: "run this on a GPU", "run this for every sample", "hold a node for an hour", "why did my job
fail?".

`euler-jobs` shows what your sessions are doing and waiting for: failed jobs no session watches, closed sessions
with queued jobs and sessions waiting for you first, then each session's status, background commands, PRs (open,
merged, closed) and jobs, the calling session's on top. Run it as `! euler-jobs` in a Claude session, or in any shell
on the node your sessions run on (see Install); agents run `euler-jobs --mine` for their own jobs, and
`euler-jobs --summary` for a Markdown table of them by partition since the session started. A job's session is
the `CLAUDE_CODE_SESSION_ID` in the environment Slurm stores with each batch job, so jobs submitted by scripts count
too; jobs without it (interactive allocations, `--export=NONE`) are matched by the directory they were submitted
from. Sessions come from Claude Code's own records, PR states from `gh`. A session on your machine passes its ID
through `euler-ssh`, so `euler-jobs --mine` lists its jobs too.

Settings, saved with `/plugin configure euler-hpc@quadbio` (the in-session `/plugin install` asks for them; a
shell install doesn't). They hold what is specific to you on Euler, so your `CLAUDE.md` needn't; on your own
machine, give them the same values.

| Setting | Default | Meaning |
| --- | --- | --- |
| `gpu_model` | `rtx_4090` | GPU model for GPU jobs; one your shareholder group can use. Blank: the agent asks. |
| `gpu_fallback` | `rtx_3090` | Model to try when the default queues too long. Blank: the agent asks. |
| `group` | | Your group's storage name, as in `/cluster/project/<group>`. |
| `work_root` | | Where your repositories and work live. |
| `notes` | | Other facts about your setup, separated by semicolons, e.g. where shared datasets live. |
| `transfer` | | How your data reaches Euler: the machines it lives on, whether Euler can reach them, Globus collections and their path roots. |

Slurm charges your default share. If you belong to several, set `SBATCH_ACCOUNT`, `SALLOC_ACCOUNT` and
`SLURM_ACCOUNT` in your shell profile.

## Install

From the [quadbio marketplace](https://github.com/quadbio/claude-plugins), then save the settings above: once on
Euler (all nodes share your home), and on each machine you work from. There, also add this entry to
`~/.ssh/config`, with your ETH username and the key you log in to Euler with (`IdentityFile`), then check it with
`euler-ssh hostname`:

```
Host euler-agents
    HostName euler.ethz.ch
    User <eth-username>
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 8h
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

`euler-jobs`, `euler-step`, `euler-resume`, `euler-caps` and `euler-ssh` are on the `PATH` of Claude sessions. For your own shell:
`uv tool install git+https://github.com/quadbio/euler-hpc`, updated with `uv tool upgrade euler-hpc`; that copy then
comes first in Claude sessions too.

## Develop

```bash
claude plugin validate .
claude --plugin-dir .            # try the hook and skill from this checkout
pre-commit run --all-files
sh tests/test_session_start.sh   # the Euler cases on Euler
sh tests/test_euler_jobs.sh
sh tests/test_euler_step.sh
sh tests/test_euler_resume.sh
sh tests/test_euler_caps.sh
sh tests/test_euler_ssh.sh
```

## Release

Bump `version` in `.claude-plugin/plugin.json` and merge: the marketplace follows `main`, and users update when the
version changes.

## License

MIT
