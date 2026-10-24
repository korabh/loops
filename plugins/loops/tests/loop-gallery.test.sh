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

expect_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$name" ;;
    *) fail "$name"; printf '      wanted to find: %s\n      in: %s\n' "$needle" "$haystack" ;;
  esac
}

mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho "https://github.com/acme/repo/pull/9"\n' >"$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test

seed="$WORK/seed"
kit="$WORK/kit"
mkdir -p "$seed/.claude/skills/loop-old" "$seed/.claude/agents" "$kit/bin" "$kit/gallery"
cp "$HERE/../bin/loop-gallery" "$HERE/../bin/loop-admin" "$kit/bin/"
cat >"$seed/.claude/loops.json" <<'JSON'
{
  "loops": [
    {
      "name": "loop-old",
      "title": "Old",
      "group": "Ship",
      "every": 24
    }
  ]
}
JSON
printf -- '---\nname: loop-old\ndescription: Daily loop. Old.\n---\n' >"$seed/.claude/skills/loop-old/SKILL.md"
printf -- '---\nname: loop-old\nmodel: opus\n---\n' >"$seed/.claude/agents/loop-old.md"
cat >"$kit/gallery/loop-new.md" <<'MD'
---
name: loop-new
title: New watcher
tagline: Watches new things.
symbol: eye
group: Watch
every: 168
hours: [9, 18]
model: sonnet
worktree: false
description: Watches new things and says so.
ships: a weekly note
---

1. **Look.** Look at new things.
   Done: a list.

2. **Result.** Brief: the list.
MD
cat >"$kit/gallery/loop-old.md" <<'MD'
---
name: loop-old
title: Old
tagline: Already here.
symbol: clock
group: Ship
every: 24
model: opus
worktree: true
description: Old things.
ships: old things
---
1. **Old.** Do old things.
MD
git -C "$seed" init -q -b main
git -C "$seed" add -A
git -C "$seed" commit -q -m seed
git clone -q --bare "$seed" "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/main"
main="$WORK/main"

run() { (cd "$main" && PATH="$WORK/bin:$PATH" bash "$kit/bin/loop-gallery" "$@") 2>&1; }
show() { git -C "$WORK/origin.git" show "$1:$2" 2>/dev/null; }

list=$(run list </dev/null)
expect_eq "list gives every template, by group then title" "$(jq -r '[.[].name] | join(" ")' <<<"$list")" "loop-old loop-new"
expect_eq "list reads numbers, booleans and hours as JSON" "$(jq -c '.[] | select(.name == "loop-new") | [.every, .hours, .worktree, .symbol, .tagline]' <<<"$list")" '[168,[9,18],false,"eye","Watches new things."]'
expect_eq "list marks a template whose loop already runs" "$(jq -c '[.[] | {(.name): .installed}] | add' <<<"$list")" '{"loop-old":true,"loop-new":false}'

out=$(run add loop-new <<<'{"hours": [10, 16], "model": "opus"}')
expect_eq "add prints the PR URL last" "$(printf '%s\n' "$out" | tail -n 1)" "https://github.com/acme/repo/pull/9"
expect_eq "add writes the loop with its group and the overridden hours" "$(show loops/add-loop-new .claude/loops.json | jq -c '.loops[] | select(.name == "loop-new")')" '{"name":"loop-new","title":"New watcher","group":"Watch","every":168,"hours":[10,16],"ships":"a weekly note"}'
skill=$(show loops/add-loop-new .claude/skills/loop-new/SKILL.md)
expect_contains "add puts the template's steps in the skill" "$skill" "1. **Look.** Look at new things."
expect_contains "add keeps the template's description behind the cadence" "$skill" 'description: "Weekly loop. Watches new things and says so."'
expect_contains "add takes the model override for the agent" "$(show loops/add-loop-new .claude/agents/loop-new.md)" "model: opus"
expect_eq "add keeps what the loop ships" "$(show loops/add-loop-new .claude/loops.json | jq -r '.loops[] | select(.name == "loop-new") | .ships')" "a weekly note"

expect_contains "a dry add shows the diff" "$(run add loop-new <<<'{"dry": true}')" '+      "hours": [9, 18]'
expect_contains "adding a loop that already runs is refused" "$(run add loop-old </dev/null)" "loop-old is already one of the loops"
expect_contains "an unknown template is refused" "$(run add loop-nope </dev/null)" "no gallery template named loop-nope"
expect_contains "overrides that are not an object are refused" "$(run add loop-new <<<'[1]')" "overrides on stdin are not a JSON object"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
