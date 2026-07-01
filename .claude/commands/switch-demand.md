Switch the active demand in the current Claude session without restarting.

Ask the user for the **ticket ID** to switch to (e.g., `PROJ-456`).

Then run, always passing `-sessionId` with the UUID from your own scratchpad directory (shown
in your system prompt) -- without it, the script may match a different, unrelated Claude
session running on the same machine:

```powershell
$wl = if ($env:WORKLOG_PATH) { $env:WORKLOG_PATH } else { "$env:USERPROFILE\GitHub\claude-worklog" }
& "$wl\scripts\switch-demand.ps1" -ticket "<TICKET_ID>" -sessionId "<YOUR_SCRATCHPAD_UUID>"
```

The script will:
- Update the session's demand file
- Display the new demand's CONTEXT.md
- Warn if the target demand is already open in another session

After switching, acknowledge the new active demand and summarize its current status and next steps from the displayed CONTEXT.md.
