#!/bin/sh
# Test bin/euler-resume against a stub `tmux` and Claude Code's session registry: a live session, an older job's
# sessions, and the last job's sessions in two tmux sessions, outside tmux and in a directory that is gone.
set -eu

resume_cmd="$(cd "$(dirname "$0")/.." && pwd)/bin/euler-resume"
tmp=$(mktemp -d)
live=""
trap 'kill $live 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/claude/sessions" "$tmp/repo/.claude/worktrees/tree"

# tmux logs its arguments; only the tmux session `main` exists; with TMUX_FAIL set, every call fails
cat >"$tmp/bin/tmux" <<'EOF'
#!/bin/sh
echo "$*" >>"$(dirname "$0")/../tmux.log"
[ -z "${TMUX_FAIL:-}" ] || { echo "no server" >&2; exit 1; }
case "$1" in has-session) [ "$3" = "=main" ] ;; new-window | new-session) echo "@9" ;; esac
EOF
chmod +x "$tmp/bin/tmux"

machine=$(cat /etc/machine-id 2>/dev/null || echo none)
now=$(($(date +%s) * 1000))
entry() {  # file, session id, machine, tmux, name, directory, minutes ago
	printf '{"pid": 1, "procStart": "0", "pidDomain": "linux:%s:pid:[1]", "sessionId": "%s", %s "name": "%s", "cwd": "%s", "updatedAt": %s}\n' \
		"$3" "$2" "${4:+\"tmux\": \"$4\",}" "$5" "$6" $((now - $7 * 60000)) >"$tmp/claude/sessions/$1.json"
}
sleep 3600 &
live=$!
printf '{"pid": %s, "procStart": "%s", "pidDomain": "linux:%s:pid:[1]", "sessionId": "live-0", "cwd": "%s", "updatedAt": %s}\n' \
	"$live" "$(awk '{print $22}' "/proc/$live/stat")" "$machine" "$tmp/repo" "$now" >"$tmp/claude/sessions/0.json"
entry 1 live-0 last "work:@4.%4" resumed "$tmp/repo" 70  # reopened here since: not offered again
entry 2 old-1 before "work:@1.%1" older "$tmp/repo" 20000
entry 3 a-1 last "work:@3.%3" a-name "$tmp/repo/.claude/worktrees/tree" 60
entry 4 b-2 last "work:@1.%1" b-name "$tmp/repo" 90
entry 5 c-3 last "main:@2.%2" c-name "$tmp/repo" 80
entry 6 d-4 last "" d-name "$tmp/repo" 100
entry 7 e-5 last "work:@5.%5" e-name "$tmp/gone" 100

run() { : >"$tmp/tmux.log"; env -u TMUX HOME="$tmp" CLAUDE_CONFIG_DIR="$tmp/claude" PATH="$tmp/bin:$PATH" python3 "$resume_cmd"; }
fail() { echo "FAIL: $1"; printf '%s\n' "$out"; cat "$tmp/tmux.log"; exit 1; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }
called() { grep -qx -- "$1" "$tmp/tmux.log"; }

out=$(run </dev/null)
expected="work
   1  b-name                   repo
   2  a-name                   repo/tree
   -  e-name                   gone (directory gone)
main
   3  c-name                   repo
revived
   4  d-name                   repo"
[ "$(printf '%s\n' "$out" | sed '1d;$d')" = "$expected" ] || fail "list by tmux session and window"
! has "older\|resumed" || fail "an older job's session, or one open again"
[ ! -s "$tmp/tmux.log" ] || fail "no answer opens nothing"

out=$(echo "2-4" | run)
called "new-session -d -s work -n a-name -c $tmp/repo/.claude/worktrees/tree -P -F #{window_id}" || fail "new tmux session"
called "new-window -d -t =main: -n c-name -c $tmp/repo -P -F #{window_id}" || fail "window in a tmux session that exists"
called "new-session -d -s revived -n d-name -c $tmp/repo -P -F #{window_id}" || fail "no tmux session recorded"
called "send-keys -t @9 claude --resume c-3 Enter" || fail "resume"
! grep -q "b-2" "$tmp/tmux.log" || fail "only the chosen ones"
has "Resumed 3 in tmux work, main, revived; tmux attach -t work$" || fail "summary"

out=$(echo "" | run)
[ "$(grep -c "send-keys" "$tmp/tmux.log")" = 4 ] || fail "Enter resumes all"

if out=$(echo "5" | run 2>&1); then fail "a number out of range"; fi
has "not a session number" || fail "error message"

if out=$(echo "1" | TMUX_FAIL=1 run 2>&1); then fail "tmux failing"; fi
has "euler-resume: tmux new-session: no server$" || fail "tmux error"

echo "euler-resume: all tests pass"
