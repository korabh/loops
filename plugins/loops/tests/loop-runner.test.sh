#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/loop-runner"
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
cat >"$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${CLAUDE_CONFIG_DIR-default}" "$*" "${LOOPS_PROBE-}" >>"$CALLS"
conf="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
case "$1 ${2:-}" in
  "agents "*) if [ -n "${NO_RUNNER:-}" ]; then echo '[]'; else printf '[{"name":"loop-runner","id":"abc12345","sessionId":"%s","state":"%s","status":"idle"%s}]\n' "${RUNNER_SESSION-s}" "${AGENT_STATE:-idle}" "${AGENT_CWD:+,\"cwd\":\"$AGENT_CWD\"}"; fi ;;
  "auth login") if [ -n "${LOGIN_AS:-}" ]; then jq --arg e "$LOGIN_AS" '.oauthAccount = {emailAddress: $e}' "$conf" >"$conf.tmp" && mv "$conf.tmp" "$conf"; fi ;;
  "auth logout") jq 'del(.oauthAccount)' "$conf" >"$conf.tmp" && mv "$conf.tmp" "$conf" ;;
  "plugin list") if [ -n "${NO_PLUGINS:-}" ]; then echo '[]'; else echo '[{"id":"loops@loops"},{"id":"loops-convex@loops"}]'; fi ;;
esac
SH
chmod +x "$WORK/bin/claude"

cat >"$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${GH_LOG:-}" ] || printf '%s\n' "$*" >>"$GH_LOG"
[ -z "${GH_FAIL:-}" ] || exit 1
case "$*" in
  "run list"*) cat "$GH_STATE/reds.json" ;;
  "api "*/jobs*) id=${2#*runs/}; cat "$GH_STATE/jobs-${id%%/*}.json" ;;
  *ready-for-agent*) cat "$GH_STATE/frontier.json" ;;
  *headRefName*) cat "$GH_STATE/loop-prs.json" ;;
  *headRefOid*) cat "$GH_STATE/heads.json" ;;
  "api "*check-runs*) cat "$GH_STATE/main-runs.json" ;;
  "api "*/status) cat "$GH_STATE/main-status.json" ;;
  "issue list"*) cat "$GH_STATE/issues.json" ;;
  "pr list"*) cat "$GH_STATE/prs.json" ;;
esac
SH
chmod +x "$WORK/bin/gh"

fixture() {
  local root="$WORK/$1"
  export HOME="$root/home" CALLS="$root/calls"
  repo="$root/repo"
  runner="$repo/.claude/worktrees/loop-runner"
  a="$HOME/.claude-a"
  b="$HOME/.claude"
  mkdir -p "$repo/scripts" "$runner/.claude/loops" "$a" "$b"
  git -C "$repo" init -q
  : >"$runner/.claude/loops/log.md"
  : >"$CALLS"
  printf '{"oauthAccount":{"emailAddress":"a@example.test"}}\n' >"$a/.claude.json"
  printf '{"oauthAccount":{"emailAddress":"b@example.test"}}\n' >"$HOME/.claude.json"
  printf '%s\n%s\n' "$a" "$b" >"$repo/.git/loop-accounts"
  printf '%s\n' "$a" >"$repo/.git/loop-account"
  mkdir -p "$repo/.git/loop-locks/loop-pr-fix" "$repo/.git/loop-locks/loop-tests"
  printf '2026-10-10T14:00:00Z in %s/.claude/worktrees/wf_1-2-3\n' "$repo" >"$repo/.git/loop-locks/loop-pr-fix/by"
  printf '2026-10-10T14:00:00Z in %s\n' "$repo" >"$repo/.git/loop-locks/loop-tests/by"
}

transcript() {
  local dir="$1/projects/$(printf '%s' "$runner" | sed 's/[^A-Za-z0-9-]/-/g')"
  mkdir -p "$dir"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"/loop 1h"}}' >"$dir/${3:-s}.jsonl"
  if [ "$2" = limited ]; then
    printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"content":[{"type":"text","text":"You have hit your session limit · resets 6:50pm (Europe/Paris)"}]}}' >>"$dir/${3:-s}.jsonl"
  else
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"green-main: clean"}]}}' >>"$dir/${3:-s}.jsonl"
  fi
  printf '%s\n' '{"type":"system","subtype":"turn_duration"}' '{"type":"cost-state"}' '{"type":"last-prompt"}' '{"type":"cost-state"}' >>"$dir/${3:-s}.jsonl"
}

limited_since() { printf '%s\n%s\n' "$1" "You have hit your session limit" >"$repo/.git/loop-limited/$(printf '%s' "$2" | tr / _)"; }

run() { (cd "$repo" && PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$@") 2>&1; }
shared() { jq -r '(.shared // [])[]' "$HOME/.loops/config.json"; }

fixture limit-moves
transcript "$a" limited
out=$(run check)
expect_contains "a limit four lines from the transcript's end moves the runner to the next account" "$out" "on b@example.test now: a@example.test hit its usage limit"
expect_eq "the next account becomes the active one" "$(cat "$repo/.git/loop-account")" "$b"
expect_contains "the session on the limited account is stopped" "$(cat "$CALLS")" "$a|stop abc12345"
expect_contains "the new session starts with the default config for ~/.claude" "$(cat "$CALLS")" "default|--bg --name loop-runner"
expect_eq "a lock the runner's workflow held is released" "$([ -d "$repo/.git/loop-locks/loop-pr-fix" ] && echo held || echo released)" released
expect_eq "a lock a person's session holds is kept" "$([ -d "$repo/.git/loop-locks/loop-tests" ] && echo held || echo released)" held
expect_contains "the limited account remembers when its limit resets" "$(run account)" "resets 6:50pm"

fixture every-account-limited
transcript "$a" limited
mkdir -p "$repo/.git/loop-limited"
limited_since "$(date +%s)" "$b"
out=$(run check)
expect_eq "with every account at its limit the runner says so" "$out" "at its usage limit on every account"
expect_eq "with every account at its limit the runner stays put" "$(cat "$repo/.git/loop-account")" "$a"
expect_missing "with every account at its limit no session starts" "$(cat "$CALLS")" "--bg"

fixture rested-account
transcript "$a" limited
mkdir -p "$repo/.git/loop-limited"
limited_since "$(($(date +%s) - 3700))" "$b"
out=$(run check)
expect_contains "an account limited over an hour ago is tried again" "$out" "on b@example.test now"

fixture signed-out-account
transcript "$a" limited
rm "$HOME/.claude.json"
out=$(run check)
expect_eq "a signed-out account is never moved to" "$out" "at its usage limit on every account"

fixture healthy
transcript "$a" ok
mkdir -p "$repo/.git/loop-limited"
limited_since "$(($(date +%s) - 600))" "$a"
out=$(run check)
expect_eq "a runner whose last turn answered is ok" "$out" "ok"
expect_missing "a working account forgets its old limit" "$(run account)" "resets"
expect_missing "a working runner is not moved" "$(cat "$CALLS")" "--bg"

projects() { printf '%s/projects/%s' "$1" "$(printf '%s' "$runner" | sed 's/[^A-Za-z0-9-]/-/g')"; }

fixture own-transcript-limited
transcript "$a" limited
touch -t 202601010000 "$(projects "$a")/s.jsonl"
transcript "$a" ok retro
expect_contains "the runner's own limited transcript counts though another session wrote later" "$(run check)" "on b@example.test now"

fixture other-transcript-limited
transcript "$a" ok
touch -t 202601010000 "$(projects "$a")/s.jsonl"
transcript "$a" limited retro
expect_eq "another session's limit in the runner's folder is not the runner's" "$(run check)" "ok"

fixture newest-transcript-without-session
transcript "$a" limited
expect_contains "with no session id the newest transcript is read" "$(RUNNER_SESSION= run check)" "on b@example.test now"

fixture blocked-job
transcript "$a" ok
mkdir -p "$a/jobs/abc12345"
printf '%s\n' '{"state":"blocked","detail":"You'"'"'ve hit your session limit · resets 4:50am (Europe/Paris)"}' >"$a/jobs/abc12345/state.json"
out=$(run check)
expect_contains "a runner job blocked at a limit counts though its transcript ends on an answer" "$out" "on b@example.test now"
expect_contains "a blocked job's limit keeps its reset time" "$(run account)" "resets 4:50am"

fixture blocked-on-question
transcript "$a" ok
mkdir -p "$a/jobs/abc12345"
printf '%s\n' '{"state":"blocked","detail":"continue"}' >"$a/jobs/abc12345/state.json"
expect_eq "a runner job blocked on something else is not at a limit" "$(run check)" "ok"

fixture use-busy
transcript "$a" ok
out=$(run account use "$b")
expect_contains "moving by hand while loops run asks for --force" "$out" "loops still running"
expect_eq "moving by hand while loops run leaves the account" "$(cat "$repo/.git/loop-account")" "$a"

fixture add-account
new="$HOME/.claude-new"
printf '{"autoMode":{}}\n' >"$a/settings.json"
printf '{"oauthAccount":{"emailAddress":"a@example.test"},"hasCompletedOnboarding":true,"mcpServers":{"context7":{}},"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$repo" >"$a/.claude.json"
out=$(run account add "$new")
expect_contains "adding an account signs it in" "$(cat "$CALLS")" "$new|auth login"
expect_contains "an unfinished sign-in says so" "$out" "is not signed in yet"
expect_eq "a new account shares the runner account's settings" "$(readlink "$new/settings.json")" "$a/settings.json"
expect_eq "a new account keeps the runner account's MCP servers and trust" "$(jq -c --arg r "$repo" '[(.mcpServers | keys), .projects[$r].hasTrustDialogAccepted, (.projects | has($r + "/.claude/worktrees/loop-runner")), .oauthAccount]' "$new/.claude.json")" '[["context7"],true,true,null]'
expect_eq "a new account joins the shared accounts after the others" "$(shared)" "$(printf '%s\n%s\n%s' "$a" "$b" "$new")"
jq '.oauthAccount = {emailAddress: "new@example.test"}' "$new/.claude.json" >"$WORK/c.json" && mv "$WORK/c.json" "$new/.claude.json"
expect_eq "a finished sign-in names both accounts" "$(run account add "$new")" "new@example.test ($new) is shared: loop-runner moves to it when a@example.test hits its usage limit, and so can any project that uses shared accounts"

fixture add-named
out=$(LOGIN_AS=n1@example.test run account add)
made=$(shared | tail -n 1)
expect_eq "add without a folder makes a fresh ~/.claude-loops-<id> for the account" "$(printf '%s' "$made" | sed -E "s#^$HOME/\.claude-loops-[a-z0-9]{6}\$#ok#")" "ok"
expect_contains "the made folder is the one that signs in" "$(cat "$CALLS")" "$made|auth login"
expect_contains "add without a folder names the folder it made" "$out" "n1@example.test ($made) is shared"
expect_eq "the made folder shares the runner account's settings" "$([ -L "$made/settings.json" ] || [ ! -e "$a/settings.json" ] && echo ok)" "ok"
LOGIN_AS=n2@example.test run account add >/dev/null
expect_eq "a second add makes a different folder" "$(shared | grep -c '\.claude-loops-')" "2"
before=$(ls -d "$HOME"/.claude-loops-* | wc -l | tr -d ' ')
out=$(run account add)
expect_contains "a sign-in that does not finish adds nothing" "$out" "the sign-in did not finish, so nothing was added"
expect_eq "a sign-in that does not finish leaves no folder behind" "$(ls -d "$HOME"/.claude-loops-* | wc -l | tr -d ' ')" "$before"
out=$(LOGIN_AS=a@example.test run account add)
expect_contains "a made folder that signs in as a rotation account adds nothing" "$out" "which $a already is, so nothing was added"
expect_eq "a made twin leaves no folder behind" "$(ls -d "$HOME"/.claude-loops-* | wc -l | tr -d ' ')" "$before"
expect_eq "a made twin is not in the rotation" "$(shared | grep -c '\.claude-loops-')" "2"

fixture add-twin
twin="$HOME/.claude-twin"
out=$(LOGIN_AS=a@example.test run account add "$twin")
expect_contains "a sign-in as an account already in the rotation is refused" "$out" "that sign-in was a@example.test, which $a already is"
expect_contains "a refused fresh sign-in is signed out again, so the next add asks to sign in" "$(cat "$CALLS")" "$twin|auth logout"
expect_eq "a refused twin stays out of the rotation" "$(shared | grep -cxF "$twin")" "0"
: >"$CALLS"
mkdir -p "$HOME/.claude-same"
printf '{"oauthAccount":{"emailAddress":"b@example.test"}}\n' >"$HOME/.claude-same/.claude.json"
out=$(run account add "$HOME/.claude-same")
expect_contains "a folder already signed in as a rotation account is refused" "$out" "stays out of the rotation"
expect_missing "a folder that was already signed in is not signed out" "$(cat "$CALLS")" "auth logout"

fixture remove
mkdir -p "$repo/.git/loop-limited"
limited_since "$(date +%s)" "$b"
out=$(run account remove "$b")
expect_eq "remove takes an account out of the rotation" "$(shared)" "$a"
expect_contains "remove says the folder stays signed in" "$out" "removed b@example.test ($b) from the rotation; its folder stays signed in"
expect_eq "remove keeps the account's usage limit, which other projects still meet" "$(ls "$HOME/.loops/limited" | wc -l | tr -d ' ')" "1"
expect_contains "the runner is never moved to a removed account" "$(transcript "$a" limited; run check)" "at its usage limit on every account"
expect_contains "the account the runner is on cannot be removed" "$(run account remove "$a")" "move it first"
expect_contains "an account outside the rotation cannot be removed" "$(run account remove "$HOME/.claude-nope")" "is not in this project's rotation"

fixture remove-sign-out
printf '%s\n%s\n%s\n' "$a" "$b" "$HOME/.claude-wrong" >"$repo/.git/loop-accounts"
mkdir -p "$HOME/.claude-wrong"
printf '{"oauthAccount":{"emailAddress":"a@example.test"}}\n' >"$HOME/.claude-wrong/.claude.json"
out=$(run account remove "$HOME/.claude-wrong" --sign-out)
expect_contains "remove --sign-out signs the folder out" "$(cat "$CALLS")" "$HOME/.claude-wrong|auth logout"
expect_eq "a signed-out folder has no account left" "$(jq -c .oauthAccount "$HOME/.claude-wrong/.claude.json")" "null"
expect_contains "remove --sign-out says so" "$out" "from the rotation and signed it out"

fixture registry
out=$(run account)
expect_eq "the first run moves the repo's accounts into the shared registry" "$(shared)" "$(printf '%s\n%s' "$a" "$b")"
expect_eq "the repo is registered using shared accounts" "$(jq -c --arg r "$repo" '.projects[$r]' "$HOME/.loops/config.json")" '{"own":[],"useShared":true}'
expect_contains "account lists each account as shared or own" "$out" "a@example.test  $a  shared"

fixture registry-limits
mkdir -p "$repo/.git/loop-limited"
limited_since "$(date +%s)" "$b"
run account >/dev/null
expect_eq "a limit the repo recorded moves to the account's own key" "$(ls "$HOME/.loops/limited")" "b@example.test@-"
expect_eq "nothing is left in the repo's limit folder" "$(ls "$repo/.git/loop-limited" | wc -l | tr -d ' ')" "0"

fixture own-first
own="$HOME/.claude-own"
mkdir -p "$own"
printf '{"oauthAccount":{"emailAddress":"own@example.test","accountUuid":"u-own","organizationUuid":"o-1"}}\n' >"$own/.claude.json"
out=$(run account add "$own" --own)
expect_contains "an own account is named as the project's" "$out" "own@example.test ($own) is this project's own account"
expect_eq "an own account is not shared" "$(shared | grep -cxF "$own")" "0"
expect_eq "the project's own accounts come before the shared ones" "$(run state | jq -c '[.accounts[] | [.email, .own]]')" '[["own@example.test",true],["a@example.test",false],["b@example.test",false]]'
transcript "$a" limited
expect_contains "a limited runner moves to its project's own account first" "$(run check)" "on own@example.test now"
expect_contains "share hands an own account to every project" "$(run account share "$own")" "is shared now"
expect_eq "a shared account joins the end of the shared list" "$(shared | tail -n 1)" "$own"
expect_contains "own takes a shared account back" "$(run account own "$own")" "is this project's own account now"

fixture own-only
expect_contains "a project can stop using shared accounts" "$(run account shared off)" "uses only its own accounts"
expect_eq "state says the project uses only its own accounts" "$(run state | jq -c '[.useShared, [.accounts[].dir]]')" "[false,[\"$a\"]]"
transcript "$a" limited
expect_eq "with no own account left it waits rather than borrow a shared one" "$(run check)" "at its usage limit on every account"
run account shared on >/dev/null
expect_eq "turning shared accounts back on restores them" "$(run state | jq -c '.useShared')" "true"

fixture two-projects
other="$WORK/two-projects/other"
mkdir -p "$other/scripts" "$other/.claude/worktrees/loop-runner/.claude/loops"
git -C "$other" init -q
printf '%s\n' "$b" >"$other/.git/loop-account"
inother() { (cd "$other" && PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$@") 2>&1; }
run account >/dev/null
inother account >/dev/null
expect_eq "a second project joins the same registry" "$(jq -c '.projects | keys | length' "$HOME/.loops/config.json")" "2"
expect_eq "a second project shares the accounts already registered" "$(shared)" "$(printf '%s\n%s' "$a" "$b")"
expect_contains "a shared account another project's runner is on cannot be removed" "$(run account remove "$b")" "the loop-runner of $other is on"
transcript "$a" limited
expect_contains "the first project moves off its limited account" "$(run check)" "on b@example.test now"
other_runner="$other/.claude/worktrees/loop-runner"
d="$b/projects/$(printf '%s' "$other_runner" | sed 's/[^A-Za-z0-9-]/-/g')"
mkdir -p "$d"
printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"content":[{"type":"text","text":"You have hit your session limit"}]}}' >"$d/s.jsonl"
expect_eq "an account another project found at its limit is skipped" "$(AGENT_CWD="$other_runner" inother check)" "at its usage limit on every account"
expect_contains "another project's own account cannot be taken" "$(inother account add "$HOME/.claude-x" --own >/dev/null; run account own "$HOME/.claude-x")" "is the own account of $other"

fixture runner-folder
expect_eq "a runner in another project's folder is not this project's" "$(AGENT_CWD=/elsewhere run status | sed -n 2p)" "loop-runner is not running"
expect_contains "attach opens this project's runner by its id" "$(run attach; cat "$CALLS")" "attach abc12345"

fixture use-returns
rm -rf "$repo/.git/loop-locks"/*
( out=$(run account use "$b"); printf '%s' "$out" >"$WORK/use-out" ) &
job=$!
for i in $(seq 1 20); do kill -0 "$job" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$job" 2>/dev/null; then hung=yes; pkill -P "$job"; kill "$job" 2>/dev/null; else hung=no; fi
sleep 1
pid=$(cat "$runner/.claude/loops/watch.pid" 2>/dev/null)
[ -n "$pid" ] && kill "$pid" 2>/dev/null
expect_eq "account use returns while the watcher it starts keeps running" "$hung" "no"
expect_contains "account use moves a running runner" "$(cat "$WORK/use-out" 2>/dev/null)" "loop-runner is on b@example.test"

fixture resume-blocked
printf '%s\n' "$$" >"$runner/.claude/loops/watch.pid"
out=$(AGENT_STATE=blocked run resume)
expect_contains "resume restarts a runner blocked on a reset limit" "$out" "loop-runner restarted on a@example.test; its first tick starts now"
expect_contains "resume stops the blocked session" "$(cat "$CALLS")" "$a|stop abc12345"
expect_contains "resume starts a new session on the same account" "$(cat "$CALLS")" "$a|--bg --name loop-runner"
expect_eq "resume releases the locks the dead runs held" "$([ -d "$repo/.git/loop-locks/loop-pr-fix" ] && echo held || echo released)" released
expect_eq "resume keeps a person's lock" "$([ -d "$repo/.git/loop-locks/loop-tests" ] && echo held || echo released)" held
expect_eq "resume stays on the same account" "$(cat "$repo/.git/loop-account")" "$a"
expect_missing "a runner started before the Loops app wrote its hooks has no extra settings" "$(cat "$CALLS")" "--settings"

fixture resume-with-hooks
printf '%s\n' "$$" >"$runner/.claude/loops/watch.pid"
printf '{"hooks":{}}\n' >"$repo/.git/loop-hooks.json"
AGENT_STATE=blocked run resume >/dev/null
expect_contains "the runner reports its lifecycle to the Loops app once the app has written its hooks" "$(cat "$CALLS")" "$a|--bg --name loop-runner --model sonnet --permission-mode auto --settings $repo/.git/loop-hooks.json"

fixture resume-configured
printf '%s\n' "$$" >"$runner/.claude/loops/watch.pid"
printf '%s\n' '{"runner":{"model":"opus","every":"2h"}}' >"$runner/.claude/loops.json"
AGENT_STATE=blocked run resume >/dev/null
expect_contains "the runner session uses the model its project names" "$(cat "$CALLS")" "--bg --name loop-runner --model opus "
expect_contains "the runner ticks at the interval its project names, on the plugin's runner prompt" "$(cat "$CALLS")" " /loop 2h /loops:runner"
: >"$CALLS"
printf 'own prompt\n' >"$runner/.claude/loop.md"
AGENT_STATE=blocked run resume >/dev/null
expect_contains "a repo's own .claude/loop.md replaces the plugin's runner prompt" "$(cat "$CALLS")" "/loop 2h"
expect_missing "and the plugin's prompt is not named" "$(cat "$CALLS")" "/loops:runner"

fixture machine-env
printf '%s\n' "$$" >"$runner/.claude/loops/watch.pid"
expect_contains "env sets a variable for this repo's runner" "$(run env LOOPS_PROBE=on-this-mac)" "LOOPS_PROBE is set for this repo's runner"
expect_eq "env lists what is set" "$(run env)" "LOOPS_PROBE=on-this-mac"
AGENT_STATE=blocked run resume >/dev/null
expect_contains "the runner session gets the repo's machine variables" "$(cat "$CALLS")" "--bg --name loop-runner"
expect_contains "with their values" "$(grep -- '--bg' "$CALLS")" "|on-this-mac"
expect_contains "a bad name is refused" "$(run env 1X=y)" "not a variable name: 1X"
run env -LOOPS_PROBE >/dev/null
expect_eq "env -KEY unsets it" "$(run env)" ""

fixture forget
expect_contains "a running runner keeps its repo registered" "$(run forget)" "stop it first"
expect_contains "forget drops a stopped repo from the registry" "$(NO_RUNNER=1 run forget)" "forgot $repo"
expect_eq "and leaves no entry behind" "$(jq -c --arg r "$repo" '.projects | has($r)' "$HOME/.loops/config.json")" "false"

fixture resume-working
printf '%s\n' "$$" >"$runner/.claude/loops/watch.pid"
out=$(AGENT_STATE=working run resume)
expect_contains "resume leaves a working runner alone" "$out" "loop-runner is working; resume restarts a runner that is blocked or stopped"
expect_missing "a refused resume stops nothing" "$(cat "$CALLS")" "stop abc12345"
expect_contains "resume --force restarts a working runner" "$(AGENT_STATE=working run resume --force)" "loop-runner restarted"

fixture resume-gone
expect_contains "resume with no runner says to start it" "$(NO_RUNNER=1 run resume)" "loop-runner is not running"

fixture state
transcript "$a" limited
expect_eq "state reports the active account's limit" "$(run state | jq -c '[.account, .limited, [.accounts[].email]]')" "[\"$a\",true,[\"a@example.test\",\"b@example.test\"]]"

fixture watched
commit() { git -C "$repo" add .claude/skills .claude/loops/conventions.md && git -C "$repo" -c user.name=t -c user.email=t@example.test commit -qm "$1" && git -C "$repo" update-ref refs/remotes/origin/main HEAD; }
mkdir -p "$repo/.claude/skills/loop-issue-queue" "$repo/.claude/loops"
echo steps >"$repo/.claude/skills/loop-issue-queue/SKILL.md"
echo rules >"$repo/.claude/loops/conventions.md"
commit base
export GH_STATE="$WORK/watched-gh"
mkdir -p "$GH_STATE"
frontier() { printf '[{"number":5,"updatedAt":"%s","assignees":[{"login":"octocat"}]},{"number":9,"updatedAt":"2026-10-10T09:00:00Z","assignees":[]}]\n' "$1" >"$GH_STATE/frontier.json"; }
frontier 2026-10-10T14:00:00Z
printf '%s\n' '[{"number":9},{"number":5},{"number":3}]' >"$GH_STATE/issues.json"
printf '%s\n' '[{"number":7}]' >"$GH_STATE/prs.json"
seen() { run inputs | jq -r '.watched["loop-issue-queue"] // "none"'; }
first=$(seen)
expect_eq "inputs fingerprints what the issue queue watches" "$(printf '%s' "$first" | sed -E 's/^[0-9a-f]{12}$/ok/')" "ok"
expect_eq "unchanged issues, PRs and skill keep the fingerprint" "$(seen)" "$first"
frontier 2026-10-10T15:00:00Z
expect_missing "a comment or claim on a ready issue changes the fingerprint" "$(seen)" "$first"
frontier 2026-10-10T14:00:00Z
printf '%s\n' '[{"number":9},{"number":5}]' >"$GH_STATE/issues.json"
expect_missing "a blocker closing changes the fingerprint" "$(seen)" "$first"
printf '%s\n' '[{"number":9},{"number":5},{"number":3}]' >"$GH_STATE/issues.json"
printf '%s\n' '[{"number":7},{"number":8}]' >"$GH_STATE/prs.json"
expect_missing "a PR opening or closing changes the fingerprint" "$(seen)" "$first"
printf '%s\n' '[{"number":7}]' >"$GH_STATE/prs.json"
expect_eq "the fingerprint comes back with the state it read" "$(seen)" "$first"
echo "more steps" >"$repo/.claude/skills/loop-issue-queue/SKILL.md"
commit skill
expect_missing "a change to the loop's skill on origin/main changes the fingerprint" "$(seen)" "$first"
frontier "$(jq -rn 'now - 10797 | floor | todate')"
young=$(seen)
sleep 4
expect_missing "a claim turning three hours old changes the fingerprint" "$(seen)" "$young"
expect_eq "with GitHub unreachable inputs carries no fingerprint" "$(GH_FAIL=1 run inputs | jq -c .watched)" "{}"

fixture idle
export GH_STATE="$WORK/idle-gh"
mkdir -p "$GH_STATE" "$runner/.claude/loops/state"
recent=$(jq -rn 'now - 86400 | floor | todate')
pr() { jq -cn --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" --arg u "${4:-$recent}" '{number: $n, headRefOid: $h, isDraft: $d, updatedAt: $u}'; }
heads() { printf '%s\n' "$@" | jq -cs . >"$GH_STATE/heads.json"; }
idling() { run inputs | jq -c .idle; }
printf '%s\n' '{"at":"2026-10-11T07:15:26Z","sha":"6eee32f0","reviewed":{"51":"aaa","56":"bbb"}}' >"$runner/.claude/loops/state/loop-pr-review.json"
heads "$(pr 51 aaa)" "$(pr 56 bbb)"
expect_eq "every open PR reviewed at its head leaves the PR reviewer idle" "$(idling)" '["loop-pr-review"]'
heads "$(pr 51 aaa)" "$(pr 56 ccc)"
expect_eq "a new head on a reviewed PR makes the PR reviewer due" "$(idling)" '[]'
heads "$(pr 51 aaa)" "$(pr 56 bbb)" "$(pr 60 ddd)"
expect_eq "a PR opened since the last review makes the PR reviewer due" "$(idling)" '[]'
heads "$(pr 51 aaa)" "$(pr 60 ddd true)"
expect_eq "an unreviewed draft leaves the PR reviewer idle" "$(idling)" '["loop-pr-review"]'
heads "$(pr 51 aaa)" "$(pr 60 ddd false 2026-08-01T00:00:00Z)"
expect_eq "an unreviewed PR untouched for 30 days leaves the PR reviewer idle" "$(idling)" '["loop-pr-review"]'
heads
expect_eq "no open PR leaves the PR reviewer idle" "$(idling)" '["loop-pr-review"]'
heads "$(pr 51 aaa)"
expect_eq "with GitHub unreachable the PR reviewer stays due" "$(GH_FAIL=1 idling)" '[]'
rm "$runner/.claude/loops/state/loop-pr-review.json"
expect_eq "with no state every open PR is unreviewed" "$(idling)" '[]'

fixture pr-fix-watch
mkdir -p "$repo/.claude/skills/loop-pr-fix" "$repo/.claude/loops" "$runner/.claude/loops/state"
echo steps >"$repo/.claude/skills/loop-pr-fix/SKILL.md"
echo rules >"$repo/.claude/loops/conventions.md"
commit base
export GH_STATE="$WORK/pr-fix-gh"
mkdir -p "$GH_STATE"
main_runs() { printf '{"check_runs":[{"name":"test","conclusion":"%s","completed_at":"2026-10-11T08:00:00Z"}]}\n' "$1" >"$GH_STATE/main-runs.json"; }
main_runs success
printf '%s\n' '{"statuses":[]}' >"$GH_STATE/main-status.json"
check() { jq -cn --arg n "$1" --arg c "$2" --arg at "${3:-2026-10-11T08:00:00Z}" '{__typename: "CheckRun", name: $n, conclusion: (if $c == "" then null else $c end), completedAt: $at}'; }
verdict() { jq -cn --arg c "$1" --arg b "$2" '{id: ("R" + $c + ($b | length | tostring)), commit: {oid: $c}, body: (if $b == "" then null else $b end)}'; }
loop_pr() { jq -cn --arg head "${HEAD_OID:-h1}" --argjson checks "[$1]" --argjson reviews "[${2:-}]" '[{number: 51, headRefName: "loop/issue-queue/49-weekly-limit", headRefOid: $head, statusCheckRollup: $checks, reviews: $reviews}, {number: 60, headRefName: "feature/x", headRefOid: "h9", statusCheckRollup: [{__typename: "CheckRun", name: "test", conclusion: "FAILURE"}], reviews: []}]' >"$GH_STATE/loop-prs.json"; }
idle() { run inputs | jq -c .idle; }
fix_seen() { run inputs | jq -r '.watched["loop-pr-fix"] // "none"'; }
loop_pr "$(check test SUCCESS)"
expect_eq "with every loop PR green the PR fixer is idle, whatever a person's PR shows" "$(idle)" '["loop-pr-fix"]'
loop_pr "$(check test FAILURE)"
expect_eq "a red on a loop PR's head gives the PR fixer work" "$(idle)" '[]'
red=$(fix_seen)
expect_eq "inputs fingerprints the PR fixer's work" "$(printf '%s' "$red" | sed -E 's/^[0-9a-f]{12}$/ok/')" "ok"
expect_eq "the same red on the same head keeps the fingerprint" "$(fix_seen)" "$red"
HEAD_OID=h2 loop_pr "$(check test FAILURE)"
expect_missing "the same red on a new head changes the fingerprint" "$(fix_seen)" "$red"
loop_pr "$(check test FAILURE),$(check test SUCCESS 2026-10-11T09:00:00Z)"
expect_eq "a re-run that passed clears the red" "$(idle)" '["loop-pr-fix"]'
loop_pr "$(check test "")"
expect_eq "a check still running is not a red" "$(idle)" '["loop-pr-fix"]'
loop_pr '{"__typename":"StatusContext","context":"Vercel - app","state":"ERROR","startedAt":"2026-10-11T08:00:00Z"}'
expect_eq "a failed status context is a red" "$(idle)" '[]'
loop_pr "$(check test FAILURE)"
main_runs failure
expect_eq "a red also red on main is loop-green-main's, not the PR fixer's" "$(idle)" '["loop-pr-fix"]'
main_runs success
printf '%s\n' '{"briefed":{"51":"h1"}}' >"$runner/.claude/loops/state/loop-pr-fix.json"
expect_eq "a red on a head the PR fixer has briefed waits for a new head" "$(idle)" '["loop-pr-fix"]'
printf '%s\n' '{"briefed":{"51":"h0"}}' >"$runner/.claude/loops/state/loop-pr-fix.json"
expect_eq "a red on a head pushed since the briefing is work again" "$(idle)" '[]'
rm "$runner/.claude/loops/state/loop-pr-fix.json"
loop_pr "$(check test SUCCESS)" "$(verdict h1 '**Verdict: merge after Act on** (2 items).')"
expect_eq "an Act on verdict on the head gives the PR fixer work" "$(idle)" '[]'
loop_pr "$(check test SUCCESS)" "$(verdict h1 '**Verdict: needs rework.**')"
expect_eq "a needs rework verdict on the head gives the PR fixer work" "$(idle)" '[]'
loop_pr "$(check test SUCCESS)" "$(verdict h0 '**Verdict: merge after Act on** (2 items).')"
expect_eq "a verdict on an older head waits for the next review" "$(idle)" '["loop-pr-fix"]'
loop_pr "$(check test SUCCESS)" "$(verdict h1 "$(printf '**Verdict: ready to merge.**\n\n### Act on\nNone.')")"
expect_eq "a ready to merge verdict is not work" "$(idle)" '["loop-pr-fix"]'
loop_pr "$(check test SUCCESS)" "$(verdict h1 '')"
expect_eq "an inline reply is not a verdict" "$(idle)" '["loop-pr-fix"]'
expect_eq "with GitHub unreachable the PR fixer is not idle" "$(GH_FAIL=1 run inputs | jq -c '[.idle, .watched]')" '[[],{}]'
loop_pr "$(check test SUCCESS)"
echo '[]' >"$GH_STATE/heads.json"
expect_eq "the PR reviewer and the PR fixer idle at once are both listed" "$(idle)" '["loop-pr-review","loop-pr-fix"]'

fixture pause
rm -rf "$repo/.git/loop-locks"
printf '%s\n' '{"loops":[{"name":"loop-green-main","every":24},{"name":"loop-pr-fix","every":1}]}' >"$runner/.claude/loops.json"
expect_contains "a loop is paused by its short name" "$(run pause green-main pr-fix)" "paused loop-pr-fix"
expect_eq "the tick sees a paused loop as busy" "$(run inputs | jq -c .busy)" '["loop-green-main","loop-pr-fix"]'
expect_eq "pause with no loop lists the paused ones" "$(run pause | sort | tr '\n' ' ')" "loop-green-main loop-pr-fix "
expect_contains "status names the paused loops" "$(run status)" "paused: "
expect_eq "state lists the paused loops" "$(run state | jq -c '.paused | sort')" '["loop-green-main","loop-pr-fix"]'
expect_eq "a paused loop is not a running one" "$(run state | jq -c .busy)" '[]'
expect_contains "a loop that does not exist is refused" "$(run pause green-mian)" "no loop named loop-green-mian"
run unpause pr-fix >/dev/null
expect_eq "an unpaused loop is due again" "$(run inputs | jq -c .busy)" '["loop-green-main"]'

fixture start
printf '%s\n' '{"setup":{"install":"echo ran >installed","copy":[".env.local","apps/shop/.env.local"],"env":[{"vars":["LOOPS_TEST_UNSET","HOME"],"without":"loop-a reads less"},{"vars":["HOME"],"without":"never shown"}]}}' >"$runner/.claude/loops.json"
printf 'KEY=1\n' >"$repo/.env.local"
mkdir -p "$repo/apps/shop"
printf 'APP=1\n' >"$repo/apps/shop/.env.local"
out=$(NO_RUNNER=1 run start)
sleep 1
pid=$(cat "$runner/.claude/loops/watch.pid" 2>/dev/null)
[ -n "$pid" ] && kill "$pid" 2>/dev/null
expect_eq "start runs the project's install in the runner checkout" "$(cat "$runner/installed" 2>/dev/null)" "ran"
expect_eq "start copies the files the project lists into the runner checkout" "$(cat "$runner/.env.local" "$runner/apps/shop/.env.local" 2>/dev/null | tr '\n' ' ')" "KEY=1 APP=1 "
expect_contains "start names unset variables and what goes without them" "$out" "unset: LOOPS_TEST_UNSET, so loop-a reads less."
expect_missing "a group whose variables are all set says nothing" "$out" "never shown"
expect_contains "start launches the runner" "$(cat "$CALLS")" "--bg --name loop-runner"

fixture start-without-plugin
printf '%s\n' '{"loops":[{"name":"loop-prod-errors","every":1,"plugin":"loops-convex"}]}' >"$runner/.claude/loops.json"
out=$(NO_RUNNER=1 NO_PLUGINS=1 run start)
expect_contains "start refuses an account without the loops plugins, naming the install" "$out" "the loops plugin is not installed for a@example.test"
expect_missing "and starts no session" "$(cat "$CALLS")" "--bg"
printf 'own prompt\n' >"$runner/.claude/loop.md"
out=$(NO_RUNNER=1 NO_PLUGINS=1 run start)
sleep 1
pid=$(cat "$runner/.claude/loops/watch.pid" 2>/dev/null)
[ -n "$pid" ] && kill "$pid" 2>/dev/null
expect_contains "a repo with its own runner prompt starts without the plugin" "$(cat "$CALLS")" "--bg --name loop-runner"

fixture config
printf '%s\n' '{"timezone":"Pacific/Kiritimati","loops":[{"name":"loop-a","title":"A","every":1},{"name":"loop-b","title":"B","every":24,"hours":[0,6]}]}' >"$runner/.claude/loops.json"
expect_eq "inputs carries the project's loops" "$(run inputs | jq -c '[.loops[].name]')" '["loop-a","loop-b"]'
expect_eq "inputs gives the hour in the project's time zone" "$(run inputs | jq -r .hour)" "$(TZ=Pacific/Kiritimati date +%H)"
rm "$runner/.claude/loops.json"
expect_eq "a project with no loops file has no loops" "$(run inputs | jq -c .loops)" '[]'
expect_eq "a project with no time zone gives the local hour" "$(run inputs | jq -r .hour)" "$(date +%H)"

fixture record
mkdir -p "$runner/.claude/loops/state"
st="$runner/.claude/loops/state/loop-pr-fix.json"
printf '%s\n' '{"at":"2026-10-11T09:00:00Z","sha":"aaa"}' >"$st"
printf '%s\n' '{"ran":[{"loop":"loop-pr-fix","result":null}]}' >"$WORK/nothing.json"
expect_contains "a run with no result is named as a miss" "$(run record "$WORK/nothing.json")" "miss 1 in a row"
expect_eq "a miss keeps the loop's window and counts" "$(jq -c '[.at, .sha, .missed]' "$st")" '["2026-10-11T09:00:00Z","aaa",1]'
run record "$WORK/nothing.json" >/dev/null
expect_eq "misses in a row add up" "$(jq -c '.missed' "$st")" "2"
printf '%s\n' '{"ran":[{"loop":"loop-pr-fix","result":{"state":{"sha":"bbb"},"brief":"fixed"}}]}' >"$WORK/done.json"
run record "$WORK/done.json" >/dev/null
expect_eq "a run with a result clears the misses" "$(jq -c '[.sha, .missed, .missedAt]' "$st")" '["bbb",null,null]'

fixture ci-events
export GH_STATE="$WORK/ci-gh" GH_LOG="$WORK/ci-gh-calls"
mkdir -p "$GH_STATE"
printf '%s\n' '[{"databaseId":1,"headBranch":"main"}]' >"$GH_STATE/reds.json"
expect_eq "a project that names no CI workflow has no CI events" "$(run ci-events --once; run ci-events --once)" ""
expect_eq "nor asks GitHub for any" "$(cat "$GH_LOG" 2>/dev/null)" ""
printf '%s\n' '{"ci":{"workflow":"check.yml","label":"self-hosted"}}' >"$runner/.claude/loops.json"
ran='{"labels":["self-hosted","mac"],"steps":[{"name":"Set up job"}]}'
printf '%s\n' '[{"databaseId":1,"headBranch":"main"}]' >"$GH_STATE/reds.json"
expect_eq "the first pass only learns which reds already exist" "$(run ci-events --once)" ""
printf '%s\n' '[{"databaseId":5,"headBranch":"loop/pr-fix/x"},{"databaseId":4,"headBranch":"feature"},{"databaseId":3,"headBranch":"main"},{"databaseId":2,"headBranch":"main"},{"databaseId":1,"headBranch":"main"}]' >"$GH_STATE/reds.json"
printf '%s\n' "{\"jobs\":[$(jq -c '. + {name: "test", conclusion: "failure"}' <<<"$ran"),$(jq -c '. + {name: "lint", conclusion: "success"}' <<<"$ran")]}" >"$GH_STATE/jobs-3.json"
printf '%s\n' '{"jobs":[{"name":"test","conclusion":"failure","labels":["ubuntu-latest"],"steps":[]}]}' >"$GH_STATE/jobs-2.json"
printf '%s\n' "{\"jobs\":[$(jq -c '. + {name: "test", conclusion: "failure"}' <<<"$ran")]}" >"$GH_STATE/jobs-4.json"
printf '%s\n' "{\"jobs\":[$(jq -c '. + {name: "typecheck", conclusion: "failure"}' <<<"$ran")]}" >"$GH_STATE/jobs-5.json"
printf '%s\n' '[{"number":42,"headRefName":"loop/pr-fix/x"}]' >"$GH_STATE/loop-prs.json"
out=$(run ci-events --once)
expect_contains "a red check on main that ran on this Mac wakes the main keeper" "$out" '{"loop":"loop-green-main","run":3,"branch":"main","failed":["test"]}'
expect_contains "a red check on a loop PR wakes the PR fixer with its PR" "$out" '{"loop":"loop-pr-fix","run":5,"branch":"loop/pr-fix/x","pr":42,"failed":["typecheck"]}'
expect_missing "a run GitHub never started wakes nobody" "$out" '"run":2'
expect_missing "a red on a person's branch wakes nobody" "$out" '"run":4'
expect_eq "a red already reported is not reported again" "$(run ci-events --once)" ""
expect_contains "ci-events reads the workflow the project names" "$(cat "$GH_LOG")" "run list --workflow check.yml --status failure"

fixture ci-label
export GH_STATE="$WORK/ci-label-gh"
mkdir -p "$GH_STATE"
printf '%s\n' '{"ci":{"workflow":"build.yml","label":"gpu"}}' >"$runner/.claude/loops.json"
printf '%s\n' '[{"databaseId":1,"headBranch":"main"}]' >"$GH_STATE/reds.json"
run ci-events --once >/dev/null
printf '%s\n' '[{"databaseId":7,"headBranch":"main"},{"databaseId":1,"headBranch":"main"}]' >"$GH_STATE/reds.json"
printf '%s\n' "{\"jobs\":[$(jq -c '. + {name: "test", conclusion: "failure"}' <<<"$ran")]}" >"$GH_STATE/jobs-7.json"
expect_eq "a red job off the runners the project names wakes nobody" "$(run ci-events --once)" ""

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
