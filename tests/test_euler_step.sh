#!/bin/sh
# Test bin/euler-step against stub `squeue` and `srun`. Runs on Linux with bash.
set -eu

step_cmd="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)/bin/euler-step"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/shared" "$tmp/local"

# Jobs: explore (123) runs, queued (124) waits, dup matches two, wide (127) spans two nodes
cat >"$tmp/bin/squeue" <<'EOF'
#!/bin/sh
case "$*" in
*--name=explore* | *"-j 123"*) echo '123|RUNNING|4|1|eu-g1-1|50:00|None' ;;
*--name=wide*) echo '127|RUNNING|2|2|eu-g1-[4,5]|50:00|None' ;;
*--name=queued*) echo '124|PENDING|4|1|n/a|1:00:00|Priority' ;;
*--name=dup*) printf '125|RUNNING|1|1|eu-g1-2|9:00|None\n126|RUNNING|1|1|eu-g1-3|9:00|None\n' ;;
esac
EOF
cat >"$tmp/bin/srun" <<'EOF'
#!/bin/sh
echo "srun $*"
echo "OMP_NUM_THREADS=${OMP_NUM_THREADS-unset} SLURM_JOB_ID=${SLURM_JOB_ID-unset}"
echo "srun: Job step's --cpus-per-task value exceeds that of job (4 > 1). Job step may never run." >&2
echo "srun: error: task 0: Exited with exit code 7" >&2
exit 7
EOF
chmod +x "$tmp/bin/"*

run() {
	cd "$tmp/shared" && env PATH="$tmp/bin:$PATH" TMPDIR="$tmp/local" SLURM_JOB_ID=999 OMP_NUM_THREADS=8 \
		"$step_cmd" "$@" 2>&1
}
fail() { echo "FAIL: $1"; printf '%s\n' "$out"; exit 1; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }

code=0
out=$(run explore python a.py) || code=$?
[ "$code" -eq 7 ] || fail "the step's exit code"
has "^euler-step: job 123 on eu-g1-1, 4 CPUs, 50:00 left$" || fail "job line"
has "^srun --jobid=123 --overlap -n1 -c4 --mem-per-cpu=0 python a.py$" || fail "the whole allocation"
has "^OMP_NUM_THREADS=unset SLURM_JOB_ID=unset$" || fail "this session's job settings cleared"
! has "may never run" || fail "the -c warning filtered"
has "^srun: error: task 0: Exited with exit code 7$" || fail "other srun messages kept"

out=$(run 123 true) || :
has "^srun --jobid=123 " || fail "by job id"
out=$(run queued true) && fail "a pending job"
has "^euler-step: job 124 is PENDING (Priority)$" || fail "pending"
out=$(run dup true) && fail "two matches"
has "^euler-step: 2 of your jobs match dup$" || fail "two matches"
out=$(run wide true) && fail "two nodes"
has "^euler-step: job 127 spans 2 nodes; a step runs one command on one node$" || fail "two nodes"
out=$(run none true) && fail "no match"
has "^euler-step: 0 of your jobs match none$" || fail "no match"
out=$(run explore python "$tmp/local/a.py") && fail "a node-local argument"
has "local/a.py is in this node's local \$TMPDIR" || fail "node-local argument"
! has "^srun" || fail "no step from node-local paths"
out=$(cd "$tmp/local" && env PATH="$tmp/bin:$PATH" TMPDIR="$tmp/local" "$step_cmd" explore true 2>&1) &&
	fail "a node-local directory"
has "is in this node's local \$TMPDIR" || fail "node-local directory"
out=$(run explore) && fail "no command"
has "^usage: euler-step" || fail "usage"

echo "ok"
