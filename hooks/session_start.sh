#!/bin/sh
# SessionStart hook: on Euler, print this session's node, allocation and the user's settings, then the always-on rules.
# Its stdout joins the agent's context. Silent elsewhere; always exits 0.
# The allocation comes from the job's SLURM_* variables: asking slurmctld can take longer than the hook may.

host=$(hostname 2>/dev/null) || exit 0
case "$host" in eu-*) ;; *) exit 0 ;; esac
[ -d /cluster/home ] || exit 0

case "$host" in
eu-login-*)
	echo "Euler: login node $host, no allocation."
	;;
*)
	if [ -z "${SLURM_JOB_ID:-}" ]; then
		echo "Euler: compute node $host, SLURM_JOB_ID unset; find the allocation with \`squeue --me -w $host\`."
	else
		cpus=${SLURM_CPUS_ON_NODE:-?}
		mb=${SLURM_MEM_PER_NODE:-$((${SLURM_MEM_PER_CPU:-0} * ${SLURM_CPUS_ON_NODE:-0}))}
		if [ "$mb" -gt 0 ] && [ $((mb % 1024)) -eq 0 ]; then mem="$((mb / 1024))G"; else mem="${mb}M"; fi
		left=""
		if [ -n "${SLURM_JOB_END_TIME:-}" ]; then
			s=$((SLURM_JOB_END_TIME - $(date +%s)))
			left=", $((s / 3600))h $((s % 3600 / 60))m left"
		fi
		echo "Euler: compute node $host, job $SLURM_JOB_ID: cpus=$cpus, mem=$mem, gpus=${SLURM_GPUS_ON_NODE:-0}$left."
	fi
	;;
esac

# The user's own setup, from the plugin settings
group=${CLAUDE_PLUGIN_OPTION_GROUP:-}
root=${CLAUDE_PLUGIN_OPTION_WORK_ROOT:-}
[ -n "$group" ] && echo "Group storage: /cluster/project/$group, /cluster/work/$group."
[ -n "$root" ] && echo "Work root: $root."
[ -n "${CLAUDE_PLUGIN_OPTION_NOTES:-}" ] && echo "User's notes: $CLAUDE_PLUGIN_OPTION_NOTES"
[ -n "${CLAUDE_PLUGIN_OPTION_TRANSFER:-}" ] && echo "Data transfer: $CLAUDE_PLUGIN_OPTION_TRANSFER"

echo
cat "$(dirname "$0")/session_context.md"
exit 0
