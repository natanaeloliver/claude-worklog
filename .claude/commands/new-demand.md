Create a new demand in the worklog system.

Ask the user for the following if not already provided:
1. **Ticket ID** — e.g., `PROJ-001`, `TSK-123`, `ISSUE-42`
2. **Demand name** — short description, e.g., "Implement user authentication"
3. **Repositories** (optional) — which repos from `repos.conf` are involved, e.g., `backend, frontend`
4. **Sprint** (optional) — e.g., `Sprint2026.S11`
5. **Type** (optional, default: `feature`) — `feature`, `bugfix`, `refactor`, `investigation`

Then run:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
& "$wl\scripts\new-demand.ps1" -ticket "<TICKET_ID>" -name "<NAME>" -repos "<REPOS>" -sprint "<SPRINT>" -type "<TYPE>"
```

After creation, show the user the path to the CONTEXT.md and remind them to fill in the Description and Business Context sections.

**This creates the structure only — it does not activate the demand.** No session state is touched,
so it is safe to run while another session is live. Tell the user how to actually work on it:

- new window: `& "$wl\scripts\open-parallel.ps1" -ticket "<TICKET_ID>"`
- current session: `/switch-demand`

> `<REPOS>` is a comma-separated list of aliases matching entries in `repos.conf`. These are just cited for reference — the actual paths live in `repos.conf`, not in the demand file.
