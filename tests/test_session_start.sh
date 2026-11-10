#!/bin/sh
# Test hooks/session_start.sh against stub `hostname` and `ssh`. The Euler cases run on Euler only: the hook checks
# /cluster/home.
set -eu

hook="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)/hooks/session_start.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

# run <hostname> <euler-agents hostname> [VAR=value ...]: the hook in a clean Slurm and plugin environment; the
# second argument is what `ssh -G euler-agents` resolves the alias to (itself: no Host entry)
run() {
	printf '#!/bin/sh\necho %s\n' "$1" >"$tmp/bin/hostname"
	printf '#!/bin/sh\necho "hostname %s"\n' "$2" >"$tmp/bin/ssh"
	chmod +x "$tmp/bin/hostname" "$tmp/bin/ssh"
	shift 2
	env -u SLURM_JOB_ID -u SLURM_CPUS_ON_NODE -u SLURM_MEM_PER_CPU -u SLURM_MEM_PER_NODE \
		-u SLURM_GPUS_ON_NODE -u SLURM_JOB_END_TIME -u CLAUDE_PLUGIN_OPTION_GROUP -u CLAUDE_PLUGIN_OPTION_WORK_ROOT \
		-u CLAUDE_PLUGIN_OPTION_NOTES -u CLAUDE_PLUGIN_OPTION_TRANSFER \
		PATH="$tmp/bin:$PATH" "$@" sh "$hook"
}
fail() { echo "FAIL: $1"; exit 1; }

# Off Euler
out=$(run my-laptop euler-agents SLURM_JOB_ID=42)
[ -z "$out" ] || fail "prints without a Host euler-agents entry"
out=$(run my-laptop euler.ethz.ch CLAUDE_PLUGIN_OPTION_GROUP=mygroup)
echo "$out" | grep -q "^Euler, from my-laptop: this session runs here" || fail "remote status: $out"
echo "$out" | grep -q "euler-ssh 'command'" || fail "euler-ssh"
echo "$out" | grep -q "hooks/session_context.md before the first" || fail "where the rules are"
[ -f "$(echo "$out" | grep -o '/[^ ]*/session_context.md')" ] || fail "rules path"
echo "$out" | grep -q "Group storage: /cluster/project/mygroup" || fail "settings off Euler"
! echo "$out" | grep -q "docs.hpc.ethz.ch" || fail "rules printed off Euler"

[ -d /cluster/home ] || { echo "ok (Euler cases skipped: not on Euler)"; exit 0; }

out=$(run eu-login-1 euler-agents)
echo "$out" | grep -q "login node" || fail "login node status"
echo "$out" | grep -q "docs.hpc.ethz.ch" || fail "rules missing"
out=$(run eu-login-1 euler.ethz.ch)
! echo "$out" | grep -q "^Euler, from" || fail "remote lines on Euler"

out=$(run eu-compute-1 euler-agents)
echo "$out" | grep -q "squeue --me" || fail "SLURM_JOB_ID unset"

end=$(($(date +%s) + 7230))
out=$(run eu-compute-1 euler-agents SLURM_JOB_ID=42 SLURM_CPUS_ON_NODE=4 SLURM_MEM_PER_CPU=2048 SLURM_GPUS_ON_NODE=1 \
	SLURM_JOB_END_TIME=$end)
echo "$out" | grep -q "job 42: cpus=4, mem=8G, gpus=1, 2h 0m left" || fail "allocation: $out"

out=$(run eu-compute-1 euler-agents SLURM_JOB_ID=42 SLURM_CPUS_ON_NODE=2 SLURM_MEM_PER_NODE=1500)
echo "$out" | grep -q "job 42: cpus=2, mem=1500M, gpus=0\.$" || fail "per-node memory: $out"

out=$(run eu-login-1 euler-agents CLAUDE_PLUGIN_OPTION_GROUP=mygroup CLAUDE_PLUGIN_OPTION_WORK_ROOT=/w \
	CLAUDE_PLUGIN_OPTION_NOTES="a; b" CLAUDE_PLUGIN_OPTION_TRANSFER="c; d")
echo "$out" | grep -q "Group storage: /cluster/project/mygroup, /cluster/work/mygroup\." || fail "group: $out"
echo "$out" | grep -q "Work root: /w\." || fail "work root"
echo "$out" | grep -q "User's notes: a; b" || fail "notes"
echo "$out" | grep -q "Data transfer: c; d" || fail "transfer"

echo "ok"
