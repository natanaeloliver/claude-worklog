Show the daily activity summary for the worklog.

Run:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\GitHub\claude-worklog" }
& "$wl\scripts\day-report.ps1"
```

To see a specific date, ask the user for the date first, then run:

```powershell
& "$wl\scripts\day-report.ps1" -Date "YYYY-MM-DD"
```

The report shows:
- Commits grouped by demand and repository
- Session log entries for the day
- Open (uncommitted) files across monitored repositories (today only)

Report the output to the user without additional commentary unless they ask questions about the activity.
