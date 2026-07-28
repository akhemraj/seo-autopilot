# SEO Autopilot

Pluggable, multi-site weekly SEO automation. For each configured site it:

1. Pulls **Ubersuggest** findings (Site Audit + keyword/content gaps) via the official Ubersuggest **MCP**.
2. Runs a headless `claude -p "/seo-weekly"` that maps findings to **scoped code edits** (title/meta, JSON-LD schema, alt text/headings, on-page copy), one commit per category.
3. Runs a **hard safety check** (`scope_guard`) before executing project code, build-gates without publishing secrets in the environment, then checks scope again.
4. Opens a **pull request** (never auto-merges) via the GitHub REST API and posts the link to **Slack**.

Scheduled per-site via macOS **launchd**. Everything lands in a PR for you to review — nothing ships automatically.

## One-time setup

1. **Ubersuggest MCP — as a LOCAL user-scoped server** (a claude.ai *connector* is NOT loaded by headless `claude -p`, so the weekly run can't see it):
   ```bash
   claude mcp add --transport http --scope user ubersuggest https://ubersuggest-mcp.neilpatelapi.com/mcp
   ```
   Authorize once interactively (`claude` → `/mcp` → ubersuggest), then verify a headless run sees it:
   ```bash
   claude -p "call ubersuggest auth_status and report the output" --allowedTools "mcp__ubersuggest__*"
   ```
   It should print your account/tier. If you name the server something other than `ubersuggest`, set `UBER_TOOLS="mcp__<name>__*"` in the profile.
2. **`jq`** — `brew install jq` (used to build/parse GitHub API JSON). **No `gh` CLI needed** — PRs go through the REST API.
3. **Slack incoming webhook** — create one for the channel you want alerts in.
4. **Fine-grained GitHub PAT** — scoped to the target repo only, permissions **Contents: R/W** + **Pull requests: R/W**, with an expiry.

## Add a site

### Interactive setup

```bash
# Example: onboard example.com as the site slug "mysite"
bin/add-site.sh mysite

# The setup prompts for the domain, repository path, schedule, scope, and caps.
# If the repository path does not exist, provide its Git URL and it will be cloned.

# Add credentials to the generated, gitignored secrets file:
#   sites/mysite.secrets
#   SLACK_WEBHOOK_URL="https://hooks.slack.com/services/…"
#   GH_TOKEN="github_pat_…"

# Validate the complete workflow without pushing, opening a PR, or posting to Slack:
bin/run.sh mysite --dry-run
```

`add-site.sh` safely handles both cases:

- **Existing clone:** reuses it without cloning again.
- **Fresh setup:** clones into `~/seo-autopilot-repos/<slug>` by default.
- **Occupied non-Git directory:** stops without overwriting anything.

It then creates the site profile, a permission-restricted secrets file, and the macOS launchd schedule. The generated schedule includes a suitable `PATH` for `claude`, Node.js, Yarn, `jq`, Git, and `curl`.

For unattended setup, provide values through `AS_*` environment variables, including `AS_DOMAIN`, `AS_REPO_PATH`, `AS_REPO_URL`, and `AS_UBERSUGGEST_TARGET`.

### Site profile fields (`sites/<slug>.conf`)

Each site has its own tracked configuration at `sites/<slug>.conf`.

#### Repository and target

| Field | Default | Description |
|---|---:|---|
| `DOMAIN` | Required | Public website domain used in logs, reports, and PR titles. |
| `REPO_PATH` | Required | Absolute path to the dedicated local Git clone the automation edits. |
| `UBERSUGGEST_TARGET` | Required | Domain or project identifier queried through the Ubersuggest MCP. |
| `BASE_BRANCH` | `main` | Branch refreshed before each run and used as the PR base. |

#### Schedule

| Field | Default | Description |
|---|---:|---|
| `SCHEDULE_HOUR` | `12` | Local start hour in 24-hour format (`0–23`). |
| `SCHEDULE_WEEKDAY` | `1` | launchd weekday: `0` = Sunday, `1` = Monday, …, `6` = Saturday. |

#### Editing scope and safety caps

| Field | Default | Description |
|---|---:|---|
| `EDITABLE_GLOBS` | `app/** components/** public/**` | Space-separated path globs the edit agent is allowed to change. |
| `EXCLUDE_GLOBS` | `node_modules/** .next/** *.lock *.env* next.config.* package.json` | Space-separated forbidden paths. Exclusions always override editable globs. |
| `MAX_FILES` | `12` | Maximum total changed files in one run. |
| `MAX_NEW_PAGES` | `2` | Maximum added Next.js App Router or Pages Router routes. |
| `MAX_DIFF_LINES` | `1500` | Maximum combined added and removed text lines. |
| `BUILD_CMD` | `yarn build` | Build validation command. Set it to an empty string to disable the build gate. |

#### Pull request and agent guidance

| Field | Default | Description |
|---|---:|---|
| `PR_LABELS` | `seo,automated` | Comma-separated labels applied to the pull request. |
| `PR_REVIEWERS` | Empty | Reserved reviewer list; currently stored but not automatically applied. |
| `NOTES` | Empty | Site-specific instructions passed to the SEO edit agent. |

## How it runs

- launchd triggers `bin/run.sh <slug>` weekly (default Mon 12:00; per-site in the profile). If the Mac is asleep, launchd runs the missed job on next wake.
- Logs: `logs/<slug>/<date>.log`. Remove a schedule: `bin/uninstall-site.sh <slug>` (keeps the profile/secrets).
- The run restores your working copy to `BASE_BRANCH` when it finishes cleanly (a failed run leaves its branch checked out for debugging).
- Re-running the same week is idempotent: it reuses `seo/weekly-<date>` and updates the existing PR instead of duplicating.

## Safety

- **PR-only** — never auto-merges. Build failure → the PR opens as a **draft** labeled `needs-fix`.
- **Scope lock** — `scope_guard` fails closed before the build: every changed file must match `EDITABLE_GLOBS`, must match none of `EXCLUDE_GLOBS` (including nested paths), and binary changes are rejected. Per-run caps (`MAX_FILES` / `MAX_NEW_PAGES` / `MAX_DIFF_LINES`) are enforced, and the worktree must contain no uncommitted edits.
- **Secret hygiene** — `GH_TOKEN` / `SLACK_WEBHOOK_URL` are passed to `curl` via `--config -` (stdin) and to `git push` via an env-reading credential helper, so they never appear in argv/`ps`, on disk, or in logs. They are also **stripped from the headless edit agent's environment** (`env -u …`) so the model that consumes untrusted Ubersuggest data can never commit them.
- Failures post a Slack alert (logging + the error trap are installed before the profile even loads).

Note: the token credential helper only applies to **HTTPS** remotes; for an SSH-form `origin`, `git push` uses your ambient SSH key (the run warns about this).

## Tests

```bash
./test/run.sh        # 87 assertions, mocked curl/claude/launchctl; Git clone uses local fixtures only
```

## Layout

```
bin/run.sh            orchestrator (deterministic git/PR/Slack; calls the agent for analysis+edits)
bin/add-site.sh       onboard a site (profile + secrets + launchd)
bin/uninstall-site.sh remove a site's schedule
lib/profile.sh        load/validate/default a site profile
lib/log.sh            logging + tee to per-run logfile
lib/notify.sh         Slack webhook (URL via stdin)
lib/git_ops.sh        preflight, idempotent branch, scope_guard, caps
lib/pr.sh             GitHub REST PR create/update (curl+jq, token off argv)
commands/seo-weekly.md tracked copy of the global ~/.claude/commands/seo-weekly.md "brain"
templates/            profile / secrets / launchd plist templates
sites/                <slug>.conf (tracked) + <slug>.secrets (gitignored, 600)
```
