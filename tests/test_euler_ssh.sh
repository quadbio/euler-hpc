#!/bin/sh
# Test bin/euler-ssh against a stub `ssh` that runs the "remote" command locally. Linux and macOS.
# shellcheck disable=SC2016  # commands for "Euler" are single-quoted on purpose
set -eu

es="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)/bin/euler-ssh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/t"

# STUB_NOHOST: no Host entry; STUB_REFUSE: refuse the first session; STUB_DOWN: no connection
cat >"$tmp/bin/ssh" <<'EOF'
#!/bin/bash
log=$(dirname "$0")/ssh.log
echo "$*" >>"$log"
case " $* " in
*" -G "*)
	[ -n "${STUB_NOHOST-}" ] && echo "hostname euler-agents" || echo "hostname euler.ethz.ch"
	echo "controlpath $(dirname "$0")/cm-socket"
	exit 0
	;;
*" -O check "*) [ -z "${STUB_DOWN-}" ]; exit ;;
*" -O exit "* | *" -fNT "*) exit 0 ;;
esac
[ -n "${STUB_DOWN-}" ] && { echo "ssh: connect to host euler.ethz.ch: Connection refused" >&2; exit 255; }
if [ -n "${STUB_REFUSE-}" ] && [ ! -e "$log.refused" ]; then
	touch "$log.refused"
	echo "mux_client_request_session: session request failed: Session open refused by peer" >&2
	exit 255
fi
for remote; do :; done
case $remote in *" rsync --server "*) echo "$remote" >"$log.rsync"; exit 0 ;; esac
# Euler has GNU timeout; a Mac may not
command -v timeout >/dev/null || timeout() {
	[ "$1" = -k ] && shift 2
	perl -e 'alarm shift; exec @ARGV or die' "$@"
	rc=$?
	[ "$rc" = 142 ] && return 124
	return "$rc"
}
eval "$remote"
EOF
chmod +x "$tmp/bin/ssh"

run() { env TMPDIR="$tmp/t" PATH="$tmp/bin:$PATH" CLAUDE_CODE_SESSION_ID=sid-1 "$es" "$@" 2>&1; }
fail() { echo "FAIL: $1"; printf '%s\n' "$out"; exit 1; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }
slots="$tmp/t/euler-ssh-$(id -u)"

out=$(run --help) || fail "--help exit code"
has "^usage: euler-ssh" || fail "--help"
has "^Host euler-agents" || fail "--help shows the Host block"
out=$(STUB_NOHOST=1 run hostname) && fail "no Host entry"
[ "$(STUB_NOHOST=1 run hostname >/dev/null || echo $?)" = 78 ] || fail "exit 78 without a Host entry"
has "^euler-ssh: no 'Host euler-agents'" || fail "no Host entry message"

out=$(run 'echo "sid=$CLAUDE_CODE_SESSION_ID"; echo "$((1 + 1))"') || fail "a command"
has "^sid=sid-1$" || fail "the session id reaches Euler"
has "^2$" || fail "the command runs as given"
grep -q "BatchMode=yes" "$tmp/bin/ssh.log" || fail "BatchMode"
out=$(printf 'from stdin\n' | run cat) || fail "stdin"
has "^from stdin$" || fail "stdin reaches the command"

out=$(run -t 1 'sleep 5') && fail "timeout"
[ "$(run -t 1 'sleep 5' >/dev/null || echo $?)" = 124 ] || fail "exit 124 on timeout"
has "^euler-ssh: timed out after 1 s" || fail "timeout message"
out=$(run -t 901 true) && fail "-t over 900"
has "at most 900 s" || fail "-t limit message"

printf '#!/bin/bash\necho "n=$# first=$1"\n' >"$tmp/script.sh"
out=$(run --run "$tmp/script.sh" "a b" c) || fail "--run a bash script"
has "^n=2 first=a b$" || fail "--run passes arguments"
printf '#!/usr/bin/env python3\nimport sys\nprint("py", sys.argv[1:])\n' >"$tmp/script.py"
out=$(run --run "$tmp/script.py" --mine) || fail "--run a python script"
has "^py \['--mine'\]$" || fail "--run picks python"
printf 'echo hi\n' >"$tmp/plain.sh"
out=$(run --run "$tmp/plain.sh") && fail "--run without #!"

out=$(run -l me euler-agents rsync --server -logDtpre.iLsfxCIvu . /cluster/scratch/x/) || fail "rsync -e"
grep -q "^timeout -k 10 900 rsync --server -logDtpre.iLsfxCIvu \. /cluster/scratch/x/$" "$tmp/bin/ssh.log.rsync" ||
	fail "rsync gets 900 s and its own arguments"
out=$(run euler-agents ls) && fail "only rsync after the alias"

start=$(date +%s)
out=$(STUB_REFUSE=1 run 'echo after refusal') || fail "retry on refusal"
has "^after refusal$" || fail "retried after a refused session"
[ $(($(date +%s) - start)) -ge 4 ] || fail "waits before retrying"

# Six slots held by a live process: a call waits until they free; a dead holder's slot is taken at once
holder=$(sh -c 'sleep 3 >/dev/null 2>&1 & echo $!')  # not our child: init reaps it, no zombie
mkdir -p "$slots"
for i in 1 2 3 4 5 6; do mkdir "$slots/slot$i" && echo "$holder" >"$slots/slot$i/pid"; done
start=$(date +%s)
out=$(run 'echo queued') || fail "queued call"
has "^queued$" || fail "queued call output"
[ $(($(date +%s) - start)) -ge 2 ] || fail "waits for a free slot"
mkdir "$slots/slot1" && echo 999999 >"$slots/slot1/pid"
out=$(run 'echo stale') || fail "stale slot"
[ ! -d "$slots/slot1" ] || fail "slot released after the call"

# Reconnect: refuses while calls run, unless forced
mkdir "$slots/slot2" && sh -c 'sleep 3 >/dev/null 2>&1 & echo $!' >"$slots/slot2/pid"
out=$(run --reconnect </dev/null) && fail "reconnect while busy"
has "1 call(s) are running" || fail "reconnect busy message"
: >"$tmp/bin/ssh.log"
out=$(run --reconnect --force </dev/null) || fail "reconnect --force"
grep -q -- "-O exit euler-agents" "$tmp/bin/ssh.log" || fail "reconnect stops the master"
grep -q -- "-fNT euler-agents" "$tmp/bin/ssh.log" || fail "reconnect starts a master"
rm -rf "$slots/slot2"

out=$(STUB_DOWN=1 run hostname) && fail "connection down"
has "euler-ssh --reconnect" || fail "reconnect hint when the connection is down"

echo "ok"
