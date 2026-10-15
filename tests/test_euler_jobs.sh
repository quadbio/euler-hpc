#!/bin/sh
# Test bin/euler-jobs against stub `squeue`, `sacct`, `tmux` and `gh`, a working, an idle, a closed and another node's
# session in Claude Code's session registry, and a transcript. Runs on Linux with python3 and bash.
set -eu

jobs_cmd="$(cd "$(dirname "$0")/.." && pwd)/bin/euler-jobs"
tmp=$(mktemp -d)
stop() { for p in $(pgrep -P "$1"); do stop "$p"; done; kill "$1" 2>/dev/null || true; }
claude="" idle=""
trap 'for p in $claude $idle; do stop "$p"; done; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/claude/sessions" "$tmp/claude/projects/p"

# Jobs: 101, the suspended 104 and the array 200 from session a (job environment), 103 from session b's directory,
# 102 hosts session a, 99 and array task 36_1 failed in session a, 92 completed and 91 was cancelled in it, 90 was
# submitted before it started, 95 failed in b's directory; 105 runs and 94 failed in session c, 93 failed in session
# d; 97, 98 and the stepped array 300 from outside Claude. sacct logs its arguments.
cat >"$tmp/bin/squeue" <<'EOF'
#!/bin/sh
echo '101|RUNNING|1:00:00|4:00:00|2026-01-01T10:00:00|2026-01-01T10:00:00|None|eu-g1-1|gres/gpu:nvidia_rtx_4090:1|N/A|8|gpu.4h|train_1|'
echo '102|RUNNING|2:00|5-00:00:00|2026-01-01T10:00:00|2026-01-01T10:00:00|None|eu-a2p-1|N/A|N/A|8|normal.120h|tunnel|'
echo '103|PENDING|0:00|1:00:00|2026-01-01T10:00:00|N/A|Priority|N/A|N/A|N/A|1|normal.4h|prep|'
echo '105|RUNNING|0:30|1:00:00|2026-01-01T10:00:00|2026-01-01T10:00:00|None|eu-g1-4|N/A|N/A|1|normal.4h|probe_2|'
case "$*" in *"-t all"*)  # squeue lists suspended and recently ended jobs only when asked for all states
	echo '104|SUSPENDED|0:10|1:00:00|2026-01-01T10:00:00|2026-01-01T10:00:00|None|eu-g1-2|N/A|N/A|1|normal.4h|hold_1|'
	echo '97|COMPLETED|10:00|1:00:00|2026-01-01T09:00:00|2026-01-01T09:00:00|None|eu-g1-3|N/A|N/A|1|normal.4h|manual|' ;;
esac
echo '200_[1-10]|PENDING|0:00|1:00:00|2026-01-01T10:00:00|N/A|Resources|N/A|N/A|N/A|8|normal.4h|sweep|'
echo '300_[0-18:2]|PENDING|0:00|1:00:00|2026-01-01T10:00:00|N/A|Resources|N/A|N/A|N/A|8|normal.4h|steps|'
EOF
cat >"$tmp/bin/sacct" <<'EOF'
#!/bin/sh
echo "$*" >>"$(dirname "$0")/../sacct.log"
case "$*" in
--env-vars*)
	for job in 101 104 99 200 36 92 91 90 105 94 93; do
		case $job in 105 | 94) sid=cccccccc-3333 ;; 93) sid=dddddddd-4444 ;; *) sid=aaaaaaaa-1111 ;; esac
		printf 'Environment used for %s (must be batch to display)\n---\nCLAUDE_CODE_SESSION_ID=%s\n' "$job" "$sid"
	done
	exit 0 ;;
*" -j "*) exit 0 ;;
esac
echo '101|101|RUNNING|01:00:00|04:00:00|2026-01-01T10:00:00|Unknown|cpu=8|/c/repo|out.log|gpu.4h|train_1'
echo '103|103|PENDING|00:00:00|01:00:00|2026-01-01T10:00:00|Unknown|cpu=1|/c/other|out.log|normal.4h|prep'
echo '99|99|OUT_OF_MEMORY|00:05:00|01:00:00|2026-01-01T09:00:00|2026-01-01T12:34:56|cpu=1,mem=4G|/c/repo|logs/%x-%j.out|normal.4h|eval'
echo '36_1|37|FAILED|00:05:00|01:00:00|2026-01-01T09:00:00|2026-01-01T12:34:56|cpu=1|/c/repo|logs/%x-%j.out|normal.4h|arr'
echo '92|92|COMPLETED|00:10:00|01:00:00|2026-01-01T09:00:00|2026-01-01T10:00:00|cpu=1|/c/repo|o|normal.24h|done'
echo '91|91|CANCELLED by 123|00:00:01|01:00:00|2026-01-01T09:00:00|2026-01-01T10:00:00|cpu=1|/c/repo|o|normal.24h|stop'
echo '90|90|COMPLETED|00:10:00|01:00:00|2025-12-30T09:00:00|2026-01-01T10:00:00|cpu=1|/c/repo|o|normal.4h|before'
echo '105|105|RUNNING|00:00:30|01:00:00|2026-01-01T10:00:00|Unknown|cpu=1|/c/idle|out.log|normal.4h|probe_2'
echo '94|94|FAILED|00:05:00|01:00:00|2026-01-01T09:00:00|2026-01-01T12:34:56|cpu=1|/c/idle|logs/%x-%j.out|normal.4h|probe_1'
echo '93|93|NODE_FAIL|00:05:00|01:00:00|2026-01-01T09:00:00|2026-01-01T12:34:56|cpu=1|/c/far|logs/%x-%j.out|normal.4h|far'
echo '95|95|TIMEOUT|01:00:00|01:00:00|2026-01-01T09:00:00|2026-01-01T12:34:56|cpu=1|/c/other|logs/%x-%j.out|normal.4h|clean'
echo '98|98|CANCELLED by 123|00:00:01|01:00:00|2026-01-01T09:00:00|2026-01-01T10:00:00|cpu=1|/elsewhere|o|normal.4h|old'
echo '97|97|COMPLETED|00:10:00|01:00:00|2026-01-01T09:00:00|2026-01-01T10:00:00|cpu=1|/elsewhere|o|normal.4h|manual'
EOF
printf '#!/bin/sh\necho main:2\n' >"$tmp/bin/tmux"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
echo '{"data":{"r0":{"p1":{"state":"MERGED"},"p2":{"state":"OPEN"}}}}'
EOF
chmod +x "$tmp/bin/"*

# Session a: a live process whose shell runs a background command, inside job 102; session b: closed; session c: a
# live process that went idle with nothing running before its job 94 failed; session d: on another node, open or not
q="'\"'\"'"  # how Claude Code quotes a single quote inside the command it evals
# shellcheck disable=SC2016 # $0 is the inner shell's
env SLURM_JOB_ID=102 bash -c 'bash -c "$0"; :' "eval 'echo ${q}x${q} > /dev/null; sleep 3600' < /dev/null && pwd -P > /dev/null" &
claude=$!
until pgrep -P "$claude" >/dev/null; do :; done
machine=$(cat /etc/machine-id 2>/dev/null || echo none)
now=$(($(date +%s) * 1000))
cat >"$tmp/claude/sessions/1.json" <<EOF
{"pid": $claude, "procStart": "$(awk '{print $22}' "/proc/$claude/stat")", "pidDomain": "linux:$machine:pid:[1]",
 "sessionId": "aaaaaaaa-1111", "cwd": "/c/repo/.claude/worktrees/tree", "tmux": "main:@2.%5", "name": "derived-a",
 "nameSource": "derived", "status": "idle", "statusUpdatedAt": $now, "updatedAt": $now}
EOF
cat >"$tmp/claude/sessions/2.json" <<EOF
{"pid": 1, "procStart": "0", "pidDomain": "linux:$machine:pid:[1]", "sessionId": "bbbbbbbb-2222", "cwd": "/c/other",
 "name": "b-session", "nameSource": "user", "updatedAt": $((now - 3600000))}
EOF
env -u SLURM_JOB_ID sleep 3600 &
idle=$!
cat >"$tmp/claude/sessions/3.json" <<EOF
{"pid": $idle, "procStart": "$(awk '{print $22}' "/proc/$idle/stat")", "pidDomain": "linux:$machine:pid:[1]",
 "sessionId": "cccccccc-3333", "cwd": "/c/idle", "name": "idle-c", "nameSource": "user", "status": "idle",
 "statusUpdatedAt": $(date -d 2026-01-01T12:00:00 +%s)000, "updatedAt": $now}
EOF
cat >"$tmp/claude/sessions/4.json" <<EOF
{"pid": 1, "procStart": "0", "pidDomain": "linux:elsewhere:pid:[1]", "sessionId": "dddddddd-4444", "cwd": "/c/far",
 "name": "remote-d", "nameSource": "user", "updatedAt": $now}
EOF
cat >"$tmp/claude/projects/p/aaaaaaaa-1111.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"train-models","sessionId":"aaaaaaaa-1111"}
{"type":"pr-link","prNumber":1,"prRepository":"org/repo","prUrl":"u"}
{"type":"pr-link","prNumber":2,"prRepository":"org/repo","prUrl":"u"}
{"type":"assistant","timestamp":"2025-12-31T12:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo 'x' > /dev/null; sleep 3600","description":"Wait for training","run_in_background":true}}]}}
EOF

run() { env -u LMOD_CMD -u COLUMNS -u TMUX_PANE ${cols:+COLUMNS=$cols} HOME="$tmp" CLAUDE_CONFIG_DIR="$tmp/claude" PATH="$tmp/bin:$PATH" python3 "$jobs_cmd" "$@"; }
fail() { echo "FAIL: $1"; printf '%s\n' "$out"; exit 1; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }

out=$(run --session zzzz)
has "^Euler jobs · .* · 2 open sessions · 3 running · 21 pending · 5 failed in 24h$" || fail "header"
has "^Host job 102 tunnel on eu-a2p-1, 4d23h left: runs 1 open session; never cancel it$" || fail "host job"
! has "^  ! train-models" || fail "an open session's failed jobs need the user"
has "^  ! b-session: clean 95 TIMEOUT; log /c/other/logs/clean-95.out$" || fail "closed session's failed job"
has "^  ! idle-c: probe_1 94 FAILED; log /c/idle/logs/probe_1-94.out$" || fail "failed after its session went idle"
has "^  ! remote-d: far 93 NODE_FAIL; log /c/far/logs/far-93.out$" || fail "failed in a session not known to be open"
has "^  ! b-session is closed but has 1 jobs queued or running$" || fail "closed session's job"
has "^train-models  main:2  repo/tree$" || fail "session header"
has "^  idle .*; background: Wait for training$" || fail "background command"
has "^  PRs  repo #2 open, #1 merged$" || fail "PRs"
has "^  running    2  train, hold$" || fail "running, suspended included"
has "^ *1× rtx_4090 · up <1m–1h of 1h–4h$" || fail "running detail"
has "^  pending   10  sweep ×10$" || fail "array counted by task"
has "^  ended      5  2 failed, 2 completed, 1 cancelled · ran 10m of 1h limits$" || fail "ended"
has "^b-session  other$" || fail "closed session header"
has "^  closed, last active 1h ago$" || fail "closed status"
has "^  (2 of these jobs matched by directory only)$" || fail "directory match"
printf '%s\n' "$out" | grep -A4 "^Not from a Claude session" | grep -q "^  pending   10  steps ×10$" || fail "stepped array"
printf '%s\n' "$out" | grep -A4 "^Not from a Claude session" | grep -q "^  ended      2  " || fail "unlinked"
[ "$(printf '%s\n' "$out" | grep -c '102')" -eq 1 ] || fail "host job listed as a job"

out=$(run --session bbbbbbbb-2222)
printf '%s\n' "$out" | grep -m1 "^train-models  \|^b-session  " | grep -q "^b-session" || fail "this session first"

out=$(cols=25 run --session zzzz)
has "^    log /c/other/logs/clean-95.out$" || fail "wrapped with an indent"
has "^       repo #2 open, #1 merged$" || fail "a repo's PRs kept together, under the first"

out=$(run --mine --session aaaaaaaa-1111)
has "^train-models  main:2  repo/tree  <- this session$" || fail "--mine header"
has "^  idle .*; background: Wait for training$" || fail "--mine shows this session's background commands"
has "^    101 .*RUNNING .*on eu-g1-1$" || fail "--mine lists live jobs"
has "^    104 .*SUSPENDED .*on eu-g1-2$" || fail "--mine lists suspended jobs"
has "^    99 .*OUT_OF_MEMORY .*log /c/repo/logs/eval-99.out$" || fail "--mine lists failed jobs"
has "^Host job 102 tunnel on eu-a2p-1, 4d23h left: runs 1 open session; never cancel it$" || fail "--mine host job"
! has "b-session\|Not from\|PRs" || fail "--mine shows only this session"

# A host job's use: what its processes hold, not the file cache; CPUs from its cpuset
cg="$tmp/cgroup/job_102"
mkdir -p "$cg"
printf 'anon 9663676416\nfile 20401094656\nshmem 1073741824\n' >"$cg/memory.stat"
echo 68719476736 >"$cg/memory.max"
echo 12-19,24 >"$cg/cpuset.cpus.effective"
echo "usage_usec 1000" >"$cg/cpu.stat"
out=$(python3 - "$jobs_cmd" "$cg" <<'EOF'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("euler_jobs", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("euler_jobs", loader))
loader.exec_module(module)
print(module.usage(Path(sys.argv[2])))
EOF
)
[ "$out" = "uses 0.0 of 9 CPUs and 10 of 64 GB now" ] || fail "usage"

out=$(run --summary --session aaaaaaaa-1111)
start=$(date -d 2025-12-31T12:00:00Z +%Y-%m-%dT%H:%M:%S)
grep -q -- "--starttime=$start" "$tmp/sacct.log" || fail "window starts with the session"
expected="Jobs since $(echo "$start" | tr T ' ' | cut -c1-16) by partition, an array counted by task:

| partition | launched | completed | failed | cancelled |
| --- | ---: | ---: | ---: | ---: |
| gpu.4h | 1 | 0 | 0 | 0 |
| normal.24h | 2 | 1 | 0 | 1 |
| normal.4h | 13 | 0 | 2 | 0 |

Not ended yet: 2 running, 10 pending."
[ "$out" = "$expected" ] || fail "--summary"
! run --summary --session zzzz 2>/dev/null || fail "--summary without a transcript"

echo "ok"
