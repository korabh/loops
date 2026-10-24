#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/prod-events"
PASSED=0
FAILED=0
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok    %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }

expect_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name"; printf '      wanted: %s\n      got:    %s\n' "$want" "$got"; fi
}

mkdir -p "$WORK/bin" "$WORK/repo/sub"
git -C "$WORK/repo" init -q
cat >"$WORK/bin/npx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >"$NPX_CWD"
cat "$NPX_OUT"
SH
chmod +x "$WORK/bin/npx"
export NPX_OUT="$WORK/out" NPX_CWD="$WORK/cwd"

cat >"$NPX_OUT" <<'LOG'
{"kind":"Completion","timestamp":1760000000.5,"identifier":"bookings:create","udfType":"Mutation","error":"Uncaught Error: slot taken"}
{"kind":"Completion","timestamp":1760000001,"identifier":"bookings:list","udfType":"Query","error":null}
{"kind":"Console","timestamp":1760000002,"messages":["hello"]}
Error: not logged in to Convex
Watching logs...
LOG

out=$(cd "$WORK/repo/sub" && PATH="$WORK/bin:$PATH" bash "$SCRIPT")
expect_eq "a failed function becomes one event with its name, kind and error" "$(sed -n 1p <<<"$out")" '{"ts":"2025-10-09T08:53:20Z","fn":"bookings:create","type":"Mutation","error":"Uncaught Error: slot taken"}'
expect_eq "a CLI failure becomes a cli event" "$(sed -n 2p <<<"$out")" '{"cli":"Error: not logged in to Convex"}'
expect_eq "successes, console lines and chatter are dropped" "$(wc -l <<<"$out" | tr -d ' ')" "2"
expect_eq "events are kept in the loop home" "$(cat "$WORK/repo/.claude/loops/prod-events.jsonl")" "$out"
expect_eq "the Convex CLI runs from the top of the checkout it is started in" "$(cat "$NPX_CWD")" "$WORK/repo"

(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" bash "$SCRIPT") >/dev/null
expect_eq "a second run appends" "$(wc -l <"$WORK/repo/.claude/loops/prod-events.jsonl" | tr -d ' ')" "4"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
