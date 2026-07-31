Show the daily activity summary for the worklog.

Run:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\github\claude-worklog" }
& "$wl\scripts\day-report.ps1"
```

To see a specific date, ask the user for the date first, then run:

```powershell
& "$wl\scripts\day-report.ps1" -Date "YYYY-MM-DD"
```

The report shows:
- Session log entries for the day, per demand — this is the source of truth
- Commits as supporting evidence, attributed by file path inside the worklog and by message in the
  monitored repos; when the commit's label disagrees with the demand owning the file, the report
  marks the divergence
- Demands that have commits but no session log entry for the day (a gap in the audit trail)
- Worklog infrastructure commits (outside `worklogs/`)
- Open (uncommitted) files across monitored repositories (today only)

Report the output to the user without additional commentary unless they ask questions about the activity.
