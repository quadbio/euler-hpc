---
name: remote
description: >-
  Reach Euler from a session that is not running on Euler (a laptop, a workstation, another server): run commands
  there, look at files and quotas, copy data to or from Euler, submit and check Slurm jobs, and set up or restore
  the shared SSH connection (essh, euler-reconnect). Trigger on "check on Euler", "what's in /cluster/…", "copy
  this to/from Euler", "download the results", "submit this on Euler", "is my Euler job done?", "is the Euler
  connection up?", "Session open refused", "master is down", "set up Euler access on this machine", or any Euler
  request from a machine whose hostname doesn't start with eu-. For jobs, also load the euler-hpc skill for the
  Slurm rules and send its commands through essh.
---

# Euler from another machine

Only for sessions **not** on Euler (`hostname` doesn't start with `eu-`, `$SLURM_JOB_ID` unset). On Euler, run
commands directly. The always-on rules (login vs compute nodes, storage, snapshots, cancelling) come from the
session-start context on Euler; off Euler it doesn't appear, so read `${CLAUDE_PLUGIN_ROOT}/hooks/session_context.md`.

## Why every command goes through `essh`

All sessions on one machine share **one** SSH connection to Euler (host alias `euler-agents`). Two limits make raw
`ssh` unsafe:

- **Euler allows about 10 concurrent sessions per connection.** Beyond that it answers `Session open refused by
  peer`, for every session on the machine, the user's own terminal included.
- **A killed local `ssh` does not stop the remote command.** `timeout 60 ssh …` or a cancelled tool call leaves the
  command running on Euler, holding its slot until it ends. Orphaned pollers have filled all ten slots before.

`essh` (this plugin's `bin/`, on the agent's `PATH`) caps the machine at 6 sessions and queues the rest, retries
refused sessions, runs the command under `timeout` **on Euler** so the slot frees whatever happens locally, and logs
to `/tmp/essh-<uid>/log`.

```bash
essh 'cmd1; cmd2'                    # default 120 s limit, enforced on Euler too
essh -t 600 'cmd'                    # at most 900 s; anything longer is an sbatch job (euler-hpc skill)
essh 'bash -s' < local_script.sh     # run a local script there
```

Exit codes: 124 hit the timeout, 75 no free slot within 10 min, 78 no username configured, 255 ssh failure (it
says when the shared connection is down).

- **Batch** related lookups into one call (`echo "== x"; …; echo "== y"; …`). Single-quote the remote command so
  `$VARS` and globs expand on Euler.
- Each call is a fresh shell: no persistent `cd`; prefix with `cd <absolute path> &&`.
- No interactive programs (`top`, `less`, `vim`, `tail -f`, `watch`): they hang the call until it times out.
- **Polling:** one poller per batch of jobs, `sleep` ≥ 60 s between checks, one `sacct` for all job IDs, stopped
  when the jobs end. Never a loop without a sleep.
- Commands land on a **login node**: light work only. Long scans, data prep and anything heavy go through Slurm.

## Looking at files

- Quotas first: `lquota` answers most "how much space" questions; `du` over a big tree belongs in a job.
- Size before reading: `ls -lh`, `wc -l`, `head -n 50`. Never `cat` a binary: `h5ls -r file.h5`,
  `python -c "import anndata as ad; print(ad.read_h5ad('f.h5ad', backed='r'))"` with the project's environment.
- On `/cluster/work` (Lustre) prefer `lfs find` over `find`; bound every search with `-maxdepth`. `/cluster/project`
  is slow NFS with a file-count quota: no recursive scans.
- Deleted or overwritten something? Look in `<dir>/.snapshot/` before recomputing (session context, rule 5).

## Copying data

```bash
rsync -av -e essh local_dir/ euler-agents:/cluster/work/<group>/…/     # to Euler
rsync -av -e essh euler-agents:/cluster/work/<group>/…/results/ ./results/   # from Euler
cat file.py | essh 'cat > /cluster/work/<group>/…/file.py'              # one small file
```

- Dry-run first (`rsync -avn …`) when the target already holds data; never `--delete` without the user's OK.
- An rsync through `essh` gets the long limit (900 s). Bigger transfers: split them into several calls, tar many small
  files first, or use Globus (docs: `/services/globus/`); ask the user before moving terabytes.
- Choose the destination by the storage table in the session context: scratch for regenerable data (deleted after
  about two weeks), work for data jobs read, project for code and small results, never home for data.
- The agent's own `/tmp` and scratch directory are local: inputs, scripts and logs a job needs must be copied to Euler
  storage first.

## Setting up the connection, once per machine

`essh` needs the user's ETH username and has no default. Ask for it; never guess it from the local login name (a
wrong name only produces failed logins). It is read, in order, from a `Host euler-agents` block in `~/.ssh/config`,
the `EULER_USER` environment variable, or a line `EULER_USER=<name>` in `~/.config/euler-hpc/config.env`. The
one-line file is enough: without a Host block, `essh` supplies the other settings itself. A Host block, if the user
prefers one:

```
Host euler-agents
    HostName euler.ethz.ch
    User <eth-username>
    ControlMaster auto
    ControlPath /tmp/ssh-mux-%i-%n
    ControlPersist 28800
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

Then try `essh 'hostname; whoami'`. Where Euler accepts the machine's SSH key without MFA, that call opens the shared
connection itself.

## When the connection is down

If a login needs password and MFA, `essh` fails and prints the exact `euler-reconnect` command. Give it to the user to
run in their own terminal (ETH network or VPN); agents cannot answer the prompt, so don't retry in a loop. The
connection then lasts until 8 h after its last session closes.

`euler-reconnect` also clears leftover remote sessions that still count against the cap, which fixes persistent
`Session open refused`. It restarts the connection, so `essh` calls in flight at that moment fail: it asks before
restarting when there are any. Calls that are only queued or being refused go through afterwards.

## Jobs from here

Load the `euler-hpc` skill and send its commands through `essh`: `essh 'cd <jobs dir> && mkdir -p logs && sbatch
--parsable job.sh'`. `euler-caps` runs as `essh 'bash -s' < "$(command -v euler-caps)"`. `euler-jobs` knows only
sessions that run on Euler; name jobs after the task (`-J <task>-…`) and keep their IDs in the task's notes.
