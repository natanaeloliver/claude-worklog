# Onboarding — claude-worklog

Step-by-step setup guide for new team members.

---

## Prerequisites

- [Claude Code](https://code.claude.com) installed and authenticated (`claude --version`)
- PowerShell 5.1 or later (`$PSVersionTable.PSVersion`)
- Git configured with your username (`git config --global user.name "your.name"`)

---

## Step 0 (optional) — Install token efficiency tools

These tools reduce Claude's token consumption significantly. Neither is required, but both are recommended.

### claude-token-efficient

No installation needed. The rules are already embedded in `CLAUDE.md` and apply automatically every session.
Source: [github.com/drona23/claude-token-efficient](https://github.com/drona23/claude-token-efficient)

### RTK — Rust Token Killer

Compresses terminal command output (git, npm, cargo…) before it reaches Claude — 76–98% reduction per command. Transparent: `git status` automatically becomes `rtk git status` via a hook.

```powershell
# 1. Download rtk.exe from https://github.com/rtk-ai/rtk/releases
#    Place it in a directory on your PATH, e.g.:
New-Item -ItemType Directory -Force "$env:USERPROFILE\.local\bin" | Out-Null
# Copy rtk.exe there, then add to PATH if not already:
# [Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$env:USERPROFILE\.local\bin", "User")

# 2. Initialize — adds PreToolUse hook to ~\.claude\settings.json automatically
rtk init -g

# 3. Verify
rtk --version
rtk gain       # shows savings analytics
```

> **Note:** `rtk init -g` modifies `~\.claude\settings.json`. Run it before `setup.ps1` so the
> hooks don't conflict. If both are configured, they coexist — RTK uses `PreToolUse`, this project
> uses `UserPromptSubmit` and `Stop`.

---

## Step 1 — Clone the repository

```powershell
git clone https://github.com/natanaeloliver/claude-worklog.git
cd claude-worklog
```

---

## Step 2 — Run setup

```powershell
.\setup.ps1
```

This script:
1. Adds `$env:WORKLOG_PATH` to your PowerShell profile (`$PROFILE.CurrentUserAllHosts`)
2. Confirms the project-level hooks (already shipped in `.claude\settings.json`) — no global
   change needed. They fire whenever you open `claude` inside this directory.
3. Creates `active_demands.txt` and `current_demand.txt`
4. Copies `repos.conf.example` to `repos.conf`

**Prefer opening Claude directly inside each of your repos instead of staying in the hub?**
Run `.\setup.ps1 -Global` instead — it additionally writes the two hooks to
`~\.claude\settings.json` (`UserPromptSubmit` → `hook_context_inject.ps1`, `Stop` →
`hook_session_log.ps1`), which is a machine-wide setting affecting every Claude Code project,
not just this one. See [README.md — Optional: multi-repo direct mode](README.md#optional-multi-repo-direct-mode)
before choosing this.

---

## Step 3 — Restart your terminal

Close and reopen your terminal (or run `. $PROFILE`) so `WORKLOG_PATH` is available.

Verify:
```powershell
$env:WORKLOG_PATH   # should print the path to claude-worklog
```

---

## Step 4 — Configure your repositories

Edit `repos.conf` and add the repositories your team works in:

```powershell
code "$env:WORKLOG_PATH\repos.conf"
```

Format: `alias=absolute_path` — one repository per line. Example:

```
backend=C:\Users\yourname\Projects\my-backend
frontend=C:\Users\yourname\Projects\my-frontend
```

These repos appear in session logs and the day report.

---

## Step 5 — Add CLAUDE.md to your team repos (only if using `-Global`)

Skip this step if you're on the default hub-only setup — Claude already has repo context via
`repos.conf` and reads/edits those repos from within the hub session.

If you ran `.\setup.ps1 -Global` and open Claude directly inside each repo, copy the template
so Claude still has repo-specific context there:

```powershell
Copy-Item "$env:WORKLOG_PATH\templates\CLAUDE.md.template" "C:\path\to\your\repo\CLAUDE.md"
```

Then fill in the `## Project Overview` section with the repo's purpose and conventions.

---

## Step 6 — (Optional) Make slash commands global

The skills in `.claude/commands/` (`/new-demand`, `/switch-demand`, etc.) are available
by default when Claude is opened inside the `claude-worklog` directory.

To make them available in **all** Claude sessions:

```powershell
$dest = "$env:USERPROFILE\.claude\commands"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item "$env:WORKLOG_PATH\.claude\commands\*" $dest
```

---

## Step 7 — Create your first demand

```powershell
cd $env:WORKLOG_PATH
.\scripts\new-demand.ps1 -ticket "PROJ-001" -name "My first demand" -sprint "Sprint2026.S11"
```

Edit the generated `CONTEXT.md`:
```powershell
code "$env:WORKLOG_PATH\worklogs\PROJ-001\CONTEXT.md"
```

---

## Step 8 — Verify the setup

Open Claude inside the hub:

```powershell
cd $env:WORKLOG_PATH
claude
```

On your first message, Claude should acknowledge the active demand context (injected by
the `UserPromptSubmit` hook). If not, check the troubleshooting section below.

If you set up `-Global` mode, repeat this check from inside one of your other repos instead.

---

## Verification checklist

```powershell
# 1. WORKLOG_PATH is set
$env:WORKLOG_PATH

# 2. Hooks are configured
Get-Content "$env:USERPROFILE\.claude\settings.json" | Select-String "hook"

# 3. Hook scripts exist
Test-Path "$env:WORKLOG_PATH\hooks\windows\hook_context_inject.ps1"
Test-Path "$env:WORKLOG_PATH\hooks\windows\hook_session_log.ps1"

# 4. Demand exists
Get-ChildItem "$env:WORKLOG_PATH\worklogs\" -Directory

# 5. Day report works
& "$env:WORKLOG_PATH\scripts\day-report.ps1"
```

---

## Troubleshooting

**Context not injected at session start**
- Check that `active_demands.txt` has a demand listed: `Get-Content "$env:WORKLOG_PATH\active_demands.txt"`
- Default (hub-only): verify you opened `claude` inside `$env:WORKLOG_PATH`, and that the hook
  is in this repo's `.claude\settings.json` under `UserPromptSubmit`
- `-Global` mode: verify the hook is in `~\.claude\settings.json` under `UserPromptSubmit`
  instead, and that the hook script path in settings.json is correct and the file exists

**Session log not updated after closing Claude**
- The `Stop` hook only fires when Claude exits cleanly (via `/exit`)
- Forced closes (window X button) may not trigger the hook
- Verify `Stop` hook is configured in `~\.claude\settings.json`

**`git pull` fails in the hook**
- Ensure the worklog repo remote is accessible (VPN if internal GitLab)
- Run `git pull origin main` manually in the worklog directory to see the error

**"demand not found" when switching**
- The demand folder must exist under `worklogs/`
- Create it first: `.\scripts\new-demand.ps1 -ticket "TICKET-ID" -name "Name"`

---

## Daily workflow

```
Morning
  └─ Open terminal → cd to the hub (claude-worklog) → claude
     └─ Claude reads CONTEXT.md automatically

During the day
  └─ Work normally — ask Claude to read/edit files in your other repos by absolute path
     (from repos.conf); it never needs you to cd into them
  └─ Use /switch-demand if you need to move to another ticket

End of day
  └─ Tell Claude what was done today (it will write session_log.md)
  └─ /exit → hook syncs everything to git automatically
```

(Running `-Global` mode instead? Replace "cd to the hub" with "cd to whichever repo you're
working in" — the hook fires the same way either place.)

---

## Key files

| File | Purpose |
|------|---------|
| `active_demands.txt` | List of currently active demands (gitignored, per-user) |
| `current_demand.txt` | Legacy single-demand pointer (gitignored, per-user) |
| `repos.conf` | Your local repository paths (gitignored, per-user) |
| `worklogs/{TICKET}/CONTEXT.md` | Demand state — read by Claude at session start |
| `worklogs/{TICKET}/session_log.md` | Audit trail — written by Claude + hooks |
