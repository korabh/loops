#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/loop-gate"
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

expect_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$name" ;;
    *) fail "$name"; printf '      wanted to find: %s\n      in: %s\n' "$needle" "$haystack" ;;
  esac
}

expect_missing() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) fail "$name"; printf '      wanted not to find: %s\n' "$needle" ;;
    *) pass "$name" ;;
  esac
}

repo="$WORK/repo"
mkdir -p "$repo/.claude"
git -C "$repo" init -q
run() { (cd "$repo" && bash "$SCRIPT" "$@") 2>&1; }

out=$(run abc123)
expect_eq "a repo with no gate steps fails the gate" "$?" "1"
expect_contains "and says why" "$out" "LOOP GATE: FAIL (no gate steps in .claude/loops.json)"

cat >"$repo/.claude/loops.json" <<'JSON'
{
  "gate": [
    { "name": "base", "run": "echo \"against $BASE\" >base.txt" },
    { "name": "types", "run": "echo 'src/a.ts(3,1): error TS2322: nope'; exit 1" },
    { "name": "suite", "run": "test ! -d \"$(git rev-parse --git-common-dir)/loop-gate-suites\" && echo outside || echo FLAKY: a.test passes alone", "alone": true },
    { "name": "lint", "run": "true" }
  ]
}
JSON
out=$(run abc123)
code=$?
expect_eq "a red step fails the gate" "$code" "1"
expect_eq "each step sees the base it is gated against" "$(cat "$repo/base.txt")" "against abc123"
expect_contains "a green step is named ok" "$out" "ok    lint"
expect_contains "every step runs after a red one" "$out" "ok    suite"
expect_contains "a red step's errors are listed at the end" "$out" "error TS2322: nope"
expect_contains "a step marked alone runs while it holds the suite lock" "$out" "FLAKY: a.test passes alone"
expect_eq "the suite lock is released" "$([ -d "$repo/.git/loop-gate-suites" ] && echo held || echo free)" "free"
expect_contains "the summary names the red steps" "$out" "LOOP GATE: FAIL (types)"

jq '.gate |= map(select(.name != "types"))' "$repo/.claude/loops.json" >"$WORK/c.json" && mv "$WORK/c.json" "$repo/.claude/loops.json"
out=$(run abc123)
expect_eq "every step green passes the gate" "$?" "0"
expect_contains "and says so" "$out" "LOOP GATE: PASS"
expect_missing "a passing gate lists no errors" "$out" "== "

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
