#!/bin/sh
# Test bin/euler-caps against stub `sacctmgr` and `squeue`.
set -eu

caps_cmd="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)/bin/euler-caps"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Accounts as Euler lists them: <partition>/<group>, with and without %, the bare group, and public
cat >"$tmp/bin/sacctmgr" <<'EOF'
#!/bin/sh
[ -n "${SACCTMGR_FAILS-}" ] && case "$*" in *"$SACCTMGR_FAILS"*) echo "sacctmgr: error" >&2; exit 1 ;; esac
case "$*" in
*assoc*) printf '%s\n' "${ASSOC-%gpu/es_x
gpu/es_x
es_x
public
%normal/public}" ;;
*qos*) cat <<'Q'
normal|
es_x/gpu/4|cpu=230,gres/gpu=24,mem=1163G
es_x/gpu|cpu=64,gres/gpu=6,mem=291G
es_x/bigmem/4|cpu=2112,gres/gpu=0,mem=32882G
es_x/bigmem/24|cpu=1109,gres/gpu=0,mem=17263G
es_y/gpu/4|cpu=1,gres/gpu=1,mem=1G
Q
;;
esac
EOF
# Two running GPU jobs (model and gpumem entries beside gres/gpu, memory in G and M), two tasks of one array
# pending on a per-user cap (one row only without -r), one on a per-job limit, one on priority, one running in
# bigmem (outside the default partitions), one in another group's QOS. Fields as `-O …:0|` prints them.
cat >"$tmp/bin/squeue" <<'EOF'
#!/bin/sh
echo "$*" >>"$(dirname "$0")/squeue.args"
[ -n "${SQUEUE_FAILS-}" ] && { echo "squeue: error: slurm_load_jobs" >&2; exit 1; }
cat <<'J'
es_x/gpu/4|billing=69468,cpu=4,gres/gpu:nvidia_geforce_rtx_4090=1,gres/gpu=1,gres/gpumem=0,mem=16G,node=1|R|None|
es_x/gpu/4|cpu=8,gres/gpu:a100_80gb=2,gres/gpu=2,gres/gpumem=0,mem=32768M,node=1|R|None|
es_x/gpu/4|cpu=8,mem=256G,node=1,billing=1|PD|QOSMaxMemoryPerUser|
es_x/gpu/4|cpu=64,mem=2T,node=1,billing=1|PD|QOSMaxMemoryPerJob|
es_x/gpu/4|cpu=1,mem=4G,node=1,billing=1|PD|Priority|
es_x/bigmem/24|cpu=16,mem=1T,node=1|R|None|
es_y/gpu/4|cpu=1,gres/gpu=1,mem=1G,node=1|R|None|
J
case " $* " in *" -r "*) echo 'es_x/gpu/4|cpu=8,mem=256G,node=1,billing=1|PD|QOSMaxMemoryPerUser|' ;; esac
EOF
chmod +x "$tmp/bin/"*

run() { env PATH="$tmp/bin:$PATH" "$caps_cmd" "$@" 2>&1; }
fail() { echo "FAIL: $1"; printf '%s\n' "$out"; exit 1; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }
line() { printf '%s\n' "$out" | grep -n -- "$1" | cut -d: -f1; }

out=$(run) || fail "exit code"
has "^QOS  *tier  *jobs  *GPUs  *CPUs  *RAM  *held$" || fail "header"
has "^es_x/gpu/4  *4h  *2  *3/24  *12/230  *48G/1163G  *2$" ||
	fail "running jobs by QOS, gres/gpu only; held: every array task, per-user reasons only"
has "^es_x/gpu  *-  *0  *0/6  *0/64  *0G/291G  *0$" || fail "the untiered QOS"
has "^es_x/bigmem/24  *24h  *1  *0/0  *16/1109  *1024G/17263G  *0$" || fail "a QOS with jobs outside the default"
! has "^es_x/bigmem/4 " || fail "bigmem without jobs hidden by default"
! has "^es_y/" || fail "another group's QOS"
! has "^normal" || fail "a QOS without a group"
[ "$(line '^es_x/bigmem/24 ')" -lt "$(line '^es_x/gpu/4 ')" ] || fail "partitions in order"
[ "$(line '^es_x/gpu/4 ')" -lt "$(line '^es_x/gpu  ')" ] || fail "tiers in order, untiered last"
has "^Held: pending jobs a per-user cap keeps waiting" || fail "held note"
grep -q -- "tres-alloc:0|" "$tmp/bin/squeue.args" || fail "squeue fields untruncated"

out=$(run --all) || fail "--all exit code"
has "^es_x/bigmem/4  *4h  *0  *0/0  *0/2112  *0G/32882G  *0$" || fail "--all shows every partition"
out=$(run es_y) || fail "named group exit code"
has "^es_y/gpu/4  *4h  *1  *1/1  *1/1  *1G/1G  *0$" || fail "a named group"
! has "^es_x/" || fail "only the named group"
! has "^Held:" || fail "no held note without held jobs"
out=$(run 'es_.') && fail "a group name is not a pattern"
has "^euler-caps: no per-user caps found for es_\.$" || fail "a group name is not a pattern"
out=$(run '[') && fail "a group name with a bracket"
has "^euler-caps: no per-user caps found for \[$" || fail "a group name with a bracket"

out=$(ASSOC="public" run) && fail "no shareholder group"
has "^euler-caps: no shareholder group found" || fail "no group message"
out=$(run es_z) && fail "a group without caps"
has "^euler-caps: no per-user caps found for es_z$" || fail "no caps message"
out=$(SQUEUE_FAILS=1 run) && fail "squeue failing"
has "^euler-caps: squeue failed" || fail "squeue failing"
! has "^QOS " || fail "no table when squeue fails"
out=$(SACCTMGR_FAILS=qos run) && fail "sacctmgr show qos failing"
has "^euler-caps: sacctmgr show qos failed" || fail "sacctmgr show qos failing"
out=$(SACCTMGR_FAILS=assoc run) && fail "sacctmgr show assoc failing"
has "^euler-caps: sacctmgr show assoc failed" || fail "sacctmgr show assoc failing"
out=$(run --bogus) && fail "an unknown option"
has "^usage: euler-caps" || fail "usage on an unknown option"
out=$(run --help) || fail "--help exit code"
has "^usage: euler-caps" || fail "--help"
out=$(run --all --help) || fail "--help after another option"
has "^usage: euler-caps" || fail "--help after another option"

# Off Euler, without the stubs: a machine without Slurm says so
if ! command -v sacctmgr >/dev/null 2>&1; then
	out=$("$caps_cmd" 2>&1) && fail "no Slurm"
	has "^euler-caps: no Slurm on " || fail "no Slurm message"
fi

echo "ok"
