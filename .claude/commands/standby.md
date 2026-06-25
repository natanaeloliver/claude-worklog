Put Claude Code in stand-by mode — clear the active demand so no context is injected in future sessions.

Run:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\GitHub\claude-worklog" }
& "$wl\scripts\standby.ps1"
```

Confirm to the user that stand-by mode is now active. Remind them that:
- No demand context will be injected in future sessions
- To resume: use `/switch-demand` or create a new demand with `/new-demand`
