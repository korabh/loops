#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

ago() { jq -nr --argjson d "$1" 'now - $d * 86400 | floor | todate'; }

run() { bash "$HERE/../bin/loop-directions" "$1" 2>&1; }

empty="$WORK/empty"
mkdir -p "$empty"
out=$(run "$empty")
expect_eq "a home with no records needs the person zero times" "$(jq -c '.needed' <<<"$out")" '{"last7":0,"prior7":0}'
expect_eq "a home with no records has no signals" "$(jq -c '[.asks, .notes, .lessons, .answers]' <<<"$out")" '[[],[],[],[]]'

home="$WORK/home"
mkdir -p "$home/.claude/loops/lessons"
cat >"$home/.claude/loops/log.md" <<MD
## $(ago 2) loop-green-main
- green-main: fixed reds.
- Needs a person: (1) legal: bump the versions; (2) design: drop the halo; (3) deps: pin nanoid.

## $(ago 3) loop-pr-fix
pr-fix: nothing to push.
Decision: fix Actions billing, then re-run Check: claude-cli://open?repo=a/b&q=re-run

## $(ago 5) loop-issue-queue
issue-queue: frontier empty since abc1234.
PR: https://github.com/a/b/pull/12
Review and merge #55: claude-cli://open?repo=a/b&q=review%2055
- Decisions for a person: merge PR #51 (claude-cli://open?repo=a/b&q=51) and PR #56 (claude-cli://open?repo=a/b&q=56); the rest waits.

## $(ago 9) loop-prod-errors
prod-errors: one signature.
Needs a person: merge #14 and deploy, then confirm the failures stop.
Needs a person: settle (3) before merging #11.

## $(ago 20) loop-help-drift
Needs a person: merge #9.

## $(ago 40) loop-old
Needs a person: merge #3.
MD
out=$(run "$home")
expect_eq "each numbered item, each deep link and each other marked line counts once, split at seven days" "$(jq -c '.needed' <<<"$out")" '{"last7":7,"prior7":2}'
expect_eq "each item keeps its loop, and a brief older than four weeks is left out" "$(jq -c '[.asks[] | .loop] | group_by(.) | map({(.[0]): length}) | add' <<<"$out")" '{"loop-green-main":3,"loop-help-drift":1,"loop-issue-queue":3,"loop-pr-fix":1,"loop-prod-errors":2}'
expect_eq "a numbered item is its own text" "$(jq -r '[.asks[] | select(.loop == "loop-green-main") | .text] | join(" | ")' <<<"$out")" 'legal: bump the versions | design: drop the halo | deps: pin nanoid.'
expect_eq "a number in parentheses mid-sentence is not a list" "$(jq -r '.asks[] | select(.loop == "loop-prod-errors") | .text' <<<"$out" | tail -n 1)" 'settle (3) before merging #11.'
expect_eq "a Decision line is an item too" "$(jq -r '.asks[] | select(.loop == "loop-pr-fix") | .text' <<<"$out")" 'fix Actions billing, then re-run Check'
expect_eq "each deep link is an item, with or without a marker" "$(jq -r '[.asks[] | select(.loop == "loop-issue-queue") | .text] | join(" | ")' <<<"$out")" 'Review and merge #55 | merge PR #51 | and PR #56'
expect_eq "an item carries its brief's time" "$(jq -r 'first(.asks[] | select(.loop == "loop-prod-errors")) | .at[0:10]' <<<"$out")" "$(ago 9 | cut -c1-10)"

{
  jq -nc --arg at "$(ago 1)" '{at: $at, loop: "loop-issue-queue", task: "Issue builder: #47", question: "Keep the uncommitted edit?", answer: "Keep it"}'
  printf '%s\n' '{"at": "2026-10-11T10:00:00Z", "loop": "loop-pr-fix", "task": "half a line'
  printf '%s\n' '42'
  jq -nc --arg at "$(ago 8)" '{at: $at, loop: null, task: "Goal: CI green", question: "It wants to run a command", answer: "Go ahead"}'
  jq -nc --arg at "$(ago 1)" '{at: $at, loop: "loop-pr-fix", task: "Fix Actions billing", question: "fix Actions billing, then re-run Check", answer: "Done", source: "brief"}'
  jq -nc --arg at "$(ago 40)" '{at: $at, loop: "loop-old", task: "Old", question: "Old?", answer: "Old"}'
} >"$home/.claude/loops/answers.jsonl"
out=$(run "$home")
expect_eq "each answer to a waiting session counts once, an answer to a brief's ask does not count again, a malformed line is skipped" "$(jq -c '.needed' <<<"$out")" '{"last7":8,"prior7":3}'
expect_eq "the answers come through with their question and answer" "$(jq -c '[.answers[] | [.task, .question, .answer]]' <<<"$out")" '[["Issue builder: #47","Keep the uncommitted edit?","Keep it"],["Goal: CI green","It wants to run a command","Go ahead"],["Fix Actions billing","fix Actions billing, then re-run Check","Done"]]'

d2=$(ago 2 | cut -c1-10)
d1=$(ago 1 | cut -c1-10)
cat >"$home/.claude/loops/notes.md" <<MD
- $(ago 40 | cut -c1-10) loop-pr-fix [ci] An old note.
- $d2 loop-pr-review [availability] getWindow has three callers.
- $d2 loop-pr-fix [ci] The Check workflow triggers on push only.
- $d2 loop-pr-fix [ci] The Check workflow triggers on push only.
- $d1 loop-pr-review [availability] The engine's zone fallback is the profile zone.
- $d1 loop-green-main [ci] Since 00:09Z GitHub Actions starts no job.
- $d1 loop-pr-review [availability] An end at midnight cannot be stored.
- $d1 loop-convex-cost [convex prod] logs --prod streams forever.
- $d1 loop-tests a note with no area.
MD
out=$(run "$home")
expect_eq "notes from the last four weeks are grouped by area, the largest first, a repeated note once" "$(jq -c '[.notes[] | {(.area): .count}] | add' <<<"$out")" '{"availability":3,"ci":2,"convex prod":1,"other":1}'
expect_eq "a grouped note keeps its date, loop and text" "$(jq -c '.notes[] | select(.area == "ci") | .notes[1]' <<<"$out")" "{\"date\":\"$d1\",\"loop\":\"loop-green-main\",\"text\":\"Since 00:09Z GitHub Actions starts no job.\"}"

printf 'lesson %s\n' 1 2 3 4 5 6 7 >"$home/.claude/loops/lessons/loop-pr-review.md"
printf '\nOnly one.\n\n' >"$home/.claude/loops/lessons/loop-tests.md"
out=$(run "$home")
expect_eq "each loop gives its newest five lessons and how many it has" "$(jq -c '.lessons' <<<"$out")" '[{"loop":"loop-pr-review","count":7,"newest":["lesson 3","lesson 4","lesson 5","lesson 6","lesson 7"]},{"loop":"loop-tests","count":1,"newest":["Only one."]}]'

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
