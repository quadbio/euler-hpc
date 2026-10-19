---
name: data
description: >-
  Move data to and from ETH Zurich's Euler cluster: rsync through the login nodes, Polybox with rclone, Globus for
  large transfers from the shell, and what stays out of backups. Trigger on "copy this to/from Euler", "download the
  results", "upload this dataset", "move the data from <server> to Euler", "start a Globus transfer", "sync with
  Polybox". The rules for every session (storage, snapshots) and the user's own data locations come from this
  plugin's session-start context.
---

# Moving data

How to move data to and from Euler. The session-start context holds the rules for every session, among them which
storage to pick, and the user's `Data transfer:` setup; if it is missing, read
`${CLAUDE_PLUGIN_ROOT}/hooks/session_context.md`. Docs paths below are relative to https://docs.hpc.ethz.ch; read
the page when you need more than the summary here.

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
