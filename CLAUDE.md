# CLAUDE.md — claude-worklog

This is the worklog hub. It is not a production codebase — it contains demand tracking,
session logs, hooks, and management scripts.

## Active Demand Context

The `UserPromptSubmit` hook injects the active demand's context automatically on the first
message of each session. If the hook did not inject (stand-by or failure), read manually:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
$t  = (Get-Content "$wl\active_demands.txt" -EA Stop | Select-Object -First 1).Trim()
Get-Content "$wl\worklogs\$t\CONTEXT.md"
```

**Stand-by:** if `active_demands.txt` is empty or missing, no context is injected — Claude
works normally without demand context.

## Working in Other Repositories

The hooks in this repo are project-level (`.claude/settings.json`) — they only fire when
Claude is opened here, in the hub. Code work in another repository happens via absolute path
(Read/Edit/Bash), always from this hub session — never by opening `claude` physically inside
that other repository. `repos.conf` maps aliases to absolute paths; use those paths directly.

(If the user has set up `-Global` mode instead, the hooks also run inside their other repos
directly — see README.md for that mode. Default assumption is hub-only unless told otherwise.)

## Token Efficiency

Rules from [claude-token-efficient](https://github.com/drona23/claude-token-efficient) — applied by default in every session:

- **Read before write** — always read the full file before editing; do not re-read unless content changed
- **Targeted edits** — prefer Edit over rewriting entire files
- **No preamble or closing** — no "Sure!", "Great question!", "Let me know if you need anything else!"
- **Concise output** — direct answer; details only when requested
- **No over-engineering** — simplest solution that solves the problem; no unsolicited abstractions
- **No multi-line comment blocks** — one short line max; never write docstrings that explain what the code does
- **User instructions prevail** — if the user asks for detail, provide it without questioning
- **Stop at first error** — report with full traceback; do not silently retry or fix around the issue

**RTK (Rust Token Killer)** — optional but recommended. Compresses terminal output (git, npm, cargo…)
before it reaches Claude — 76–98% reduction per command. See ONBOARDING.md for setup.

---

## Session Conventions

### At the end of each session

1. Update `## Next Steps` in the active demand's `CONTEXT.md`
2. Record technical decisions in `## Technical Decisions`
3. Write the day's entry in `session_log.md`:

```markdown
## YYYY-MM-DD username

What was done this session (1-3 objective lines).

Repos: repo1, repo2
```

> If an entry already exists for today and the current user, **append** to it.

### session_log.md — required detail level

Each entry must cover:
- **Tests performed and results** — what was tested, values returned, success/failure
- **Files consulted** — scripts, models, queries read or analyzed
- **Logic understood** — business rules, data structures, discovered behaviors
- **Files created or modified** — scripts, models, queries, configs
- **Conclusions** — technical decisions made and rationale

### CONTEXT.md vs session_log.md

| Goes in CONTEXT.md | Goes in session_log.md |
|---|---|
| Conclusion of an analysis | Details of tests that led to the conclusion |
| Technical decision and brief rationale | Query results, returned values |
| Next steps | Files consulted during investigation |
| Artifact status by repository | Approaches that didn't work and why |

## Switching Demands

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
& "$wl\scripts\switch-demand.ps1" -ticket "TICKET-123" -sessionId "SESSION_ID_FROM_SCRATCHPAD"
```

**Always pass `-sessionId`** with the UUID from your own scratchpad directory (shown in your
system prompt). Without it, the script falls back to a heuristic that can match a DIFFERENT,
unrelated Claude session running on the same machine, silently switching the wrong session's
demand (confirmed via live debugging, 2026-07-01).

## Management Commands

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }

# Create new demand
& "$wl\scripts\new-demand.ps1" -ticket "PROJ-001" -name "Demand name" -sprint "Sprint2026.S11"

# Stand-by (no active demand)
& "$wl\scripts\standby.ps1"

# View all demands
Get-ChildItem "$wl\worklogs\" -Directory | Select-Object Name

# View active demands
Get-Content "$wl\active_demands.txt"
```

## Parallel Sessions

```powershell
& "$wl\scripts\open-parallel.ps1" -ticket "PROJ-456"
```

Each session tracks its own active demand independently. Claude warns when two sessions
open the same demand simultaneously.
