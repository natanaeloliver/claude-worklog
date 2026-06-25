# Bash Hooks (Linux / macOS)

Bash equivalents of the Windows PowerShell hooks are planned but not yet implemented.

## What needs to be ported

| File | Description |
|------|-------------|
| `hook_context_inject.sh` | Equivalent of `../windows/hook_context_inject.ps1` |
| `hook_session_log.sh` | Equivalent of `../windows/hook_session_log.ps1` |

## Key differences from PowerShell

- `$TMPDIR` instead of `$env:TEMP`
- `kill -0 $PID` for process liveness check instead of `Get-Process`
- `jq` for JSON parsing instead of `ConvertFrom-Json`
- No `wt new-tab` — terminal-specific (gnome-terminal, kitty, iTerm2, etc.)
- `$HOME/.claude/projects/` instead of `$env:USERPROFILE\.claude\projects\`

## Contributing

PRs are welcome. The logic is documented in the PowerShell hooks — the Bash
translation should be a structural port, not a rewrite.

Please include a test on at least one Linux distribution before submitting.
