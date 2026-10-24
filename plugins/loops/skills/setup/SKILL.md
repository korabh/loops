---
name: setup
description: Set a repo up to run loops - writes .claude/loops.json and .claude/loops/project.md from what the repo already has, checks the skills the loops use, and opens a pull request. Use when asked to set up, add or install loops in a repo.
disable-model-invocation: true
---

Set this repo up for the loops plugin. Read `${CLAUDE_PLUGIN_ROOT}/skills/loops/SKILL.md` first: it says what each key is for. Ask the person only what the repo cannot tell you, all at once, with your proposed answer for each.

1. **Read the repo.** The package manager and its lockfile, the workspaces, the scripts in each `package.json` (or the `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`), the GitHub workflows in `.github/workflows/` and the runner labels their jobs use, the files a fresh checkout needs that git ignores (`.env.local` and the like, from the README and `.gitignore`), and whether the repo has a `convex/` folder.

2. **Write `.claude/loops.json`**:
   - `name`, and `about`: one sentence on the codebase that names its main test commands;
   - `timezone`: the person's, from `date +%Z` or their answer;
   - `setup.install`: the frozen install (`bun install --frozen-lockfile`, `npm ci`, `pnpm install --frozen-lockfile`, `uv sync --frozen`); `setup.copy`: the ignored files a checkout needs;
   - `runner`: `{"model": "sonnet", "every": "1h"}`;
   - `gate`: typecheck, lint and the test suites, each a step; a slow or stateful suite with `"alone": true`;
   - `ci`: the workflow that runs on pushes to main and PRs, and the label of the runners it uses when they are self-hosted;
   - `loops`, each with `"plugin": "loops"`: `loop-issue-queue` and `loop-pr-review` every hour, `loop-pr-fix` every hour with `"idleFor": 24`, `loop-green-main` and `loop-tests` daily, `loop-dep-drift`, `loop-correct` and `loop-parked-branches` weekly. With a `convex/` folder and the `loops-convex` plugin, add `loop-convex-review` daily and `loop-convex-cost` weekly with `"plugin": "loops-convex"`, and `loop-prod-errors` hourly with `"hours": [8, 20]` and a monitor `{"description": "prod errors", "command": "prod-events", "wakes": "loop-prod-errors", "hours": [8, 20], "cooldown": 10}`.

   Run `loop-gate HEAD` once from the repo: every step must be one that passes on main today.

3. **Write `.claude/loops/project.md`**, short, only what the repo cannot show a loop at a glance: how tests reach code (the seams, any test that loads modules by name), the source roots, the paths that handle authentication or authorization, the login of a review bot that comments on PRs, how a deployment-preview check is reproduced, where production errors and logs are read, and the fast-moving dependencies `loop-dep-drift` watches.

4. **Ignore the runner's files**: add to `.gitignore` `.claude/worktrees/`, `.claude/loops/state/`, `.claude/loops/lessons/`, `.claude/loops/log.md`, `.claude/loops/notes.md`, `.claude/loops/answers.jsonl`, `.claude/loops/prod-events.jsonl` and `.claude/loops/watch.pid`.

5. **Enable the plugins for everyone who opens the repo**: run `claude plugin install loops@loops --scope project` (and `loops-convex@loops` with Convex). It installs the plugin for this Claude config folder and adds `enabledPlugins` to `.claude/settings.json`; add `"extraKnownMarketplaces": {"loops": {"source": {"source": "github", "repo": "korabh/loops"}, "autoUpdate": true}}` there yourself when it is missing, since the install leaves it out once the marketplace is known to your user settings. Everyone else who opens the repo, and every config folder the runner uses that does not share this one's plugins, runs the same install once; `loop-runner account add` links new folders to this one's plugins.

6. **Check the skills the loops use.** The loops load `tdd`, `pr`, `blast-radius`, `code-review`, `review-spec`, `interrogate`, `implement-spec`, `correct` and `writing-for-agents` when the repo or the user has them, and read their files for panels. List the ones missing from `.claude/skills/` and `~/.claude/skills/`, and say where each comes from, as the plugin's README lists. A loop runs without them, with a thinner review.

7. **Open a pull request** with all of it. Then tell the person to run `loop-runner start` from the repo once it merges, or to add the repo in the Loops app.
