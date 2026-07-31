Put Claude Code in stand-by mode — clear the active demand so no context is injected in future sessions.

Run, always passing `-sessionId` with the UUID of your own scratchpad directory (shown in your
system prompt) — without it the script falls back to a fragile heuristic that can match a
DIFFERENT, unrelated Claude session running on the same machine:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
& "$wl\scripts\standby.ps1" -sessionId "YOUR_SCRATCHPAD_UUID"
```

Confirm to the user that stand-by mode is now active. Remind them that:
- No demand context will be injected in future sessions — the script clears both
  `active_demands.txt` (this session) and `last_demand.txt` (the resume point)
- To resume: use `/switch-demand` or create a new demand with `/new-demand`
