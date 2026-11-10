---
name: connect
description: >-
  Reach ETH Zurich's Euler cluster from a Claude session on another machine (a laptop, a workstation, the desktop
  app): run commands there with euler-ssh, set up its shared ssh connection once, and restore it. Trigger on "set up
  Euler access on this machine", "connect to Euler from here", "is the Euler connection up?", "Session open
  refused", or a failed euler-ssh call. Jobs and data from such a session stay with the jobs and data skills; this
  plugin's session-start context says when a session runs off Euler.
---

# Euler from another machine

All sessions on a machine share one ssh connection to Euler, the `Host euler-agents` entry in `~/.ssh/config`.
Euler refuses more than 10 sessions per connection, for every session on the machine, and a killed local `ssh`
leaves its command running on Euler and holding a session. `euler-ssh` keeps within that: at most 6 calls at once,
the rest queue; refused sessions are retried; each command runs under `timeout` on Euler. So every command for
Euler goes through it, never plain `ssh`.

## Calls

```bash
euler-ssh 'cmd1; cmd2'                                    # a login node, 120 s
euler-ssh -t 600 'cmd'                                    # at most 900 s; anything longer is a Slurm job
euler-ssh 'cd /cluster/work/<group>/x && sbatch --parsable' < job.sh   # submit a local job script
rsync -a -e euler-ssh ./dir/ euler-agents:/cluster/work/<group>/dir/   # files, at most 900 s per call
```

- Batch related checks into one call (`echo "== x"; …; echo "== y"; …`): each call holds a slot until it ends.
- Single-quote the command, so variables and globs expand on Euler. Each call starts a fresh shell in your Euler
  home: use absolute paths.
- Nothing interactive (`less`, `vim`, `tail -f`, `watch`): it holds a slot until the timeout.
- `euler-caps`, `euler-jobs --mine` and `euler-step` run on Euler by themselves; paths they take are Euler paths.
  The full `euler-jobs` overview and `--summary` need a session on Euler.
- Jobs submitted through `euler-ssh` carry this session's ID, so `euler-jobs --mine` lists them.
- Exit codes: 124 timed out, and was killed on Euler too; 75 no free slot within 10 minutes (other calls on this
  machine); 78 no `Host euler-agents` entry (set up below); 255 ssh failed; when it adds that there is no
  connection, see below.

## Setting up, once per machine

1. Ask the user for their ETH username and the key they log in to Euler with; never guess either.
2. The user adds the entry to `~/.ssh/config` (`euler-ssh --help` prints it), with `IdentityFile` for that key:

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

   Keep `ControlPath` short: macOS caps socket paths at 104 bytes, which a path under `$TMPDIR` exceeds.
3. `euler-ssh hostname`. Where Euler accepts the key without a prompt, this call opens the shared connection;
   otherwise the user runs `euler-ssh --reconnect` once.
4. With Claude Code's sandbox on, ssh can't reach Euler from inside it: the user lists `euler-ssh` and `rsync` in
   `sandbox.excludedCommands`.

## When the connection is down

`euler-ssh` says so and names the fix: the user runs `euler-ssh --reconnect` in their own terminal (password and
MFA, if Euler asks). Agents can't answer the prompt, so don't retry in a loop. It also clears leftover sessions
behind a lasting `Session open refused`. Calls running at that moment fail, so it asks first when there are any.
