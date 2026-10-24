#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../bin/loop-admin"
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

mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
echo "Creating pull request..."
echo "https://github.com/acme/repo/pull/7"
SH
chmod +x "$WORK/bin/gh"
export GH_CALLS="$WORK/gh-calls" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test

seed="$WORK/seed"
mkdir -p "$seed/.claude/agents"
cat >"$seed/.claude/loops.json" <<'JSON'
{
  "name": "Seed",
  "runner": {
    "model": "sonnet"
  },
  "loops": [
    {
      "name": "loop-a",
      "title": "Alpha",
      "group": "Ship",
      "every": 1
    },
    {
      "name": "loop-b",
      "title": "Beta",
      "every": 24,
      "hours": [0, 6],
      "alone": true
    },
    {
      "name": "loop-c",
      "title": "Gamma",
      "every": 168,
      "idleFor": 48
    }
  ]
}
JSON
for l in a b c; do
  mkdir -p "$seed/.claude/skills/loop-$l"
  printf -- '---\nname: loop-%s\ndescription: Hourly loop. Does %s.\ndisable-model-invocation: true\n---\n\nSteps for %s.\n' "$l" "$l" "$l" >"$seed/.claude/skills/loop-$l/SKILL.md"
  printf -- '---\nname: loop-%s\ndescription: Loop worker, dispatched by the loop runner.\nmodel: opus\nisolation: worktree\n---\n\nRead `.claude/skills/loop-%s/SKILL.md` and follow it.\n' "$l" "$l" >"$seed/.claude/agents/loop-$l.md"
done
mkdir -p "$seed/.claude/skills/other"
printf -- '---\nname: other\ndescription: Mentions loop-c.\n---\n\nAsk loop-c.\n' >"$seed/.claude/skills/other/SKILL.md"
git -C "$seed" init -q -b main
git -C "$seed" add -A
git -C "$seed" commit -q -m seed
git clone -q --bare "$seed" "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/main"
main="$WORK/main"

run() { (cd "$main" && PATH="$WORK/bin:$PATH" bash "$SCRIPT") 2>&1 <<<"$1"; }
show() { git -C "$WORK/origin.git" show "$1:$2" 2>/dev/null; }
entry() { show "$1" .claude/loops.json | jq -c --arg n "$2" '.loops[] | select(.name == $n)'; }
names() { show "$1" .claude/loops.json | jq -r '[.loops[].name] | join(" ")'; }

: >"$GH_CALLS"
out=$(run '{"action":"add","name":"loop-foo","title":"Foo finder","group":"Guard","every":24,"hours":[8,20],"model":"sonnet","worktree":false,"description":"Finds foo: every kind.","ships":"one foo PR","steps":"1. **Find** foo.\n2. **Fix** it.\n\n"}')
expect_eq "add prints the PR URL as its last line" "$(printf '%s\n' "$out" | tail -n 1)" "https://github.com/acme/repo/pull/7"
expect_eq "add writes the entry with its title, group, hours and what it ships" "$(entry loops/add-loop-foo loop-foo)" '{"name":"loop-foo","title":"Foo finder","group":"Guard","every":24,"hours":[8,20],"ships":"one foo PR"}'
expect_eq "add places the entry after the last loop with the same or shorter cadence" "$(names loops/add-loop-foo)" "loop-a loop-b loop-foo loop-c"
expect_eq "add keeps the rest of the config" "$(show loops/add-loop-foo .claude/loops.json | jq -c '[.name, .runner]')" '["Seed",{"model":"sonnet"}]'
expect_contains "add writes short lists on one line, as JSON formatters do" "$(show loops/add-loop-foo .claude/loops.json)" '"hours": [8, 20]'
expect_eq "add keeps what the loop ships in its entry" "$(show loops/add-loop-foo .claude/loops.json | jq -r '.loops[] | select(.name == "loop-foo") | .ships')" "one foo PR"
skill=$(show loops/add-loop-foo .claude/skills/loop-foo/SKILL.md)
expect_contains "add's skill says its cadence first and quotes a description with a colon" "$skill" 'description: "Daily loop. Finds foo: every kind."'
expect_contains "add's skill runs on the loop conventions" "$skill" 'Read the loop conventions first, at the path your prompt names or `$(loop-runner kit)/conventions.md`'
expect_contains "add's skill carries the steps it was given" "$skill" "2. **Fix** it."
expect_eq "add's skill ends on its last step, with no blank line after it" "$(show loops/add-loop-foo .claude/skills/loop-foo/SKILL.md >"$WORK/skill.md"; tail -c 2 "$WORK/skill.md" | od -An -c | tr -d ' ')" '.\n'
agent=$(show loops/add-loop-foo .claude/agents/loop-foo.md)
expect_contains "add's agent uses the chosen model" "$agent" "model: sonnet"
expect_contains "add's agent stops at the default turn cap" "$agent" "maxTurns: 200"
expect_missing "add's agent without a worktree has no isolation" "$agent" "isolation"
expect_contains "add's agent loads no Artifact tool, worktree tool or MCP server" "$agent" "disallowedTools: Artifact, EnterWorktree, mcp__*"
expect_contains "add's agent points at its skill" "$agent" 'Read `.claude/skills/loop-foo/SKILL.md` and follow it.'
expect_contains "add opens the PR against main with a titled commit" "$(cat "$GH_CALLS")" "--base main --head loops/add-loop-foo --title chore(loops): add loop-foo, daily, 08–20"
expect_eq "add leaves no worktree behind" "$(git -C "$main" worktree list | wc -l | tr -d ' ')" "1"

out=$(run '{"action":"add","name":"loop-a","title":"Again","every":1,"description":"x","ships":"x","steps":"x"}')
expect_contains "add refuses a loop that exists" "$out" "loop-a already exists"
expect_eq "a refused add pushes nothing" "$(git -C "$WORK/origin.git" branch --list 'loops/add-loop-a*' | wc -l | tr -d ' ')" "0"

expect_contains "add needs steps" "$(run '{"action":"add","name":"loop-x","title":"X","every":1,"description":"x","ships":"x"}')" "add needs steps"
expect_contains "a name outside loop-<words> is refused" "$(run '{"action":"add","name":"Loop_X"}')" "name is loop-<words>"
expect_contains "hours outside 0-24 are refused" "$(run '{"action":"edit","name":"loop-a","hours":[8,30]}')" "hours is [start, end]"
expect_contains "a group with a quote is refused" "$(run "{\"action\":\"edit\",\"name\":\"loop-a\",\"group\":\"O'Brien\"}")" "group is letters"
expect_contains "a title with a quote is refused" "$(run "{\"action\":\"edit\",\"name\":\"loop-a\",\"title\":\"Bob's\"}")" "title is letters"
expect_contains "a turn cap under 10 is refused" "$(run '{"action":"edit","name":"loop-a","turns":5}')" "turns is a whole number, 10 or more"
expect_contains "an unknown action is refused" "$(run '{"action":"rename","name":"loop-a"}')" "action is add, edit or remove"
expect_contains "editing a loop that does not exist is refused" "$(run '{"action":"edit","name":"loop-zz","every":2}')" "no loop named loop-zz"

: >"$GH_CALLS"
out=$(run '{"action":"edit","name":"loop-b","title":"Beta two","every":2,"hours":null,"alone":false,"ships":"b and more","model":"fable","worktree":false,"turns":90}')
expect_eq "edit prints the PR URL as its last line" "$(printf '%s\n' "$out" | tail -n 1)" "https://github.com/acme/repo/pull/7"
expect_eq "edit rewrites the entry, dropping cleared hours and alone" "$(entry loops/edit-loop-b loop-b)" '{"name":"loop-b","title":"Beta two","every":2,"ships":"b and more"}'
expect_eq "edit keeps the loop in its place" "$(names loops/edit-loop-b)" "loop-a loop-b loop-c"
expect_eq "edit rewrites what the loop ships" "$(show loops/edit-loop-b .claude/loops.json | jq -r '.loops[] | select(.name == "loop-b") | .ships')" "b and more"
expect_contains "a new cadence renames the description's prefix" "$(show loops/edit-loop-b .claude/skills/loop-b/SKILL.md)" "description: Two-hourly loop. Does b."
agent=$(show loops/edit-loop-b .claude/agents/loop-b.md)
expect_contains "edit changes the agent's model" "$agent" "model: fable"
expect_eq "edit sets the agent's turn cap once, after its model" "$(printf '%s\n' "$agent" | grep -A1 '^model:' | tail -n 1)/$(printf '%s\n' "$agent" | grep -c '^maxTurns:')" "maxTurns: 90/1"
expect_missing "worktree false drops isolation" "$agent" "isolation"
expect_contains "edit's PR shows the entry before and after" "$(cat "$GH_CALLS")" '- {"name":"loop-b","title":"Beta","every":24,"hours":[0,6],"alone":true}'
expect_contains "edit's PR shows the entry after" "$(cat "$GH_CALLS")" '+ {"name":"loop-b","title":"Beta two","every":2,"ships":"b and more"}'

run '{"action":"edit","name":"loop-c","description":"Watches c."}' >/dev/null
run '{"action":"edit","name":"loop-c","every":24}' >/dev/null
expect_eq "edit keeps keys it does not manage" "$(entry "$(git -C "$WORK/origin.git" branch --list 'loops/edit-loop-c-*' | tr -d ' *' | head -n 1)" loop-c)" '{"name":"loop-c","title":"Gamma","every":24,"idleFor":48}'
run '{"action":"edit","name":"loop-a","group":"Watch"}' >/dev/null
expect_eq "edit moves a loop to another group" "$(entry loops/edit-loop-a loop-a)" '{"name":"loop-a","title":"Alpha","group":"Watch","every":1}'
run '{"action":"edit","name":"loop-a","group":null}' >/dev/null
expect_eq "a null group takes the loop out of its group" "$(entry "$(git -C "$WORK/origin.git" branch --list 'loops/edit-loop-a-*' | tr -d ' *' | head -n 1)" loop-a)" '{"name":"loop-a","title":"Alpha","every":1}'
expect_contains "a new description keeps the cadence prefix" "$(show loops/edit-loop-c .claude/skills/loop-c/SKILL.md)" 'description: "Weekly loop. Watches c."'
expect_contains "an edit that changes nothing says so" "$(run '{"action":"edit","name":"loop-a","every":1}')" "nothing changed"
expect_eq "two changes to one loop seconds apart each get their own branch" "$(git -C "$WORK/origin.git" branch --list 'loops/edit-loop-a*' | wc -l | tr -d ' ')" "2"

: >"$GH_CALLS"
run '{"action":"remove","name":"loop-c"}' >/dev/null
expect_eq "remove drops the entry" "$(names loops/remove-loop-c)" "loop-a loop-b"
expect_eq "remove deletes the skill and the agent" "$(git -C "$WORK/origin.git" ls-tree -r --name-only loops/remove-loop-c | grep -c 'loop-c')" "0"
expect_contains "remove's PR names the files that still mention the loop" "$(cat "$GH_CALLS")" '- `.claude/skills/other/SKILL.md`'

pushed=$(git -C "$WORK/origin.git" branch --list 'loops/edit-loop-a*' | wc -l | tr -d ' ')
local=$(git -C "$main" branch --list 'loops/edit-loop-a*' | wc -l | tr -d ' ')
out=$(run '{"action":"edit","name":"loop-a","every":3,"dry":true}')
expect_contains "a dry run prints the diff" "$out" '+      "every": 3'
expect_eq "a dry run pushes nothing" "$(git -C "$WORK/origin.git" branch --list 'loops/edit-loop-a*' | wc -l | tr -d ' ')" "$pushed"
expect_eq "a dry run, or a run that stops before pushing, leaves no branch" "$(git -C "$main" branch --list 'loops/edit-loop-a*' | wc -l | tr -d ' ')" "$local"
expect_eq "a dry run leaves no worktree" "$(git -C "$main" worktree list | wc -l | tr -d ' ')" "1"

run '{"action":"edit","name":"loop-b","every":168}' >/dev/null
expect_eq "a second change to the same loop gets its own branch" "$(git -C "$WORK/origin.git" branch --list 'loops/edit-loop-b-*' | wc -l | tr -d ' ')" "1"

jq '.loops += [{"name": "loop-kit", "title": "Kit", "every": 24, "plugin": "loops"}]' "$main/.claude/loops.json" >"$WORK/k.json"
git -C "$main" fetch -q origin
git -C "$main" checkout -q -B kit origin/main
cp "$WORK/k.json" "$main/.claude/loops.json"
git -C "$main" commit -qam kit
git -C "$main" push -q origin kit:main
git -C "$main" checkout -q main
git -C "$main" reset -q --hard origin/main
expect_contains "a plugin loop's skill and agent cannot change here" "$(run '{"action":"edit","name":"loop-kit","model":"haiku"}')" "loop-kit comes from the loops plugin"
: >"$GH_CALLS"
run '{"action":"edit","name":"loop-kit","every":168}' >/dev/null
expect_eq "a plugin loop's cadence changes in the config" "$(entry loops/edit-loop-kit loop-kit)" '{"name":"loop-kit","title":"Kit","every":168,"plugin":"loops"}'
run '{"action":"remove","name":"loop-kit"}' >/dev/null
expect_contains "removing a plugin loop only drops its entry" "$(cat "$GH_CALLS")" "its entry in the runner's cadences. Its state"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
