<#
.SYNOPSIS
    Automated setup for claude-worklog.
    Sets WORKLOG_PATH in your PowerShell profile and creates initial tracking files.
    By default, hooks stay project-level (already shipped in .claude/settings.json) -- you
    always open `claude` inside this directory, and Claude reaches your other repos via
    absolute paths (see repos.conf). Pass -Global to additionally register the hooks in
    ~/.claude/settings.json, which lets you open `claude` directly inside any repo instead --
    but that applies to every Claude Code project on this machine, not just this one, and can
    interact with hooks/settings other projects already have. Opt-in for that reason.

.PARAMETER Global
    Also register the hooks in ~/.claude/settings.json (multi-repo direct-open mode).

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -Global
#>

param(
    [switch]$Global
)

$worklogRoot = $PSScriptRoot
$profilePath = $PROFILE.CurrentUserAllHosts

Write-Host ""
Write-Host "=== claude-worklog setup ===" -ForegroundColor Cyan
Write-Host ""

# 1. WORKLOG_PATH in PowerShell profile
Write-Host "[1/4] Configuring WORKLOG_PATH environment variable..." -ForegroundColor Yellow

$envLine = "`$env:WORKLOG_PATH = `"$worklogRoot`""
$profileContent = if (Test-Path $profilePath) { Get-Content $profilePath -Raw -Encoding utf8 } else { "" }

if ($profileContent -match 'WORKLOG_PATH') {
    Write-Host "      WORKLOG_PATH already set in profile. Skipping." -ForegroundColor DarkGray
} else {
    Add-Content -Path $profilePath -Value "`n# claude-worklog`n$envLine" -Encoding utf8
    Write-Host "      Added to: $profilePath" -ForegroundColor Green
}

$env:WORKLOG_PATH = $worklogRoot

# 2. Hooks: project-level ships already configured in .claude/settings.json (this repo).
#    Only touch the global ~/.claude/settings.json if -Global was passed.
Write-Host "[2/4] Configuring Claude Code hooks..." -ForegroundColor Yellow

if (-not $Global) {
    Write-Host "      Project-level hooks already shipped in .claude\settings.json -- nothing to do." -ForegroundColor DarkGray
    Write-Host "      They fire whenever you open 'claude' inside this directory." -ForegroundColor DarkGray
    Write-Host "      Run '.\setup.ps1 -Global' if you also want to open Claude directly inside" -ForegroundColor DarkGray
    Write-Host "      your other repos (registers the hooks in ~/.claude/settings.json instead)." -ForegroundColor DarkGray
} else {
    $claudeSettingsDir  = "$env:USERPROFILE\.claude"
    $claudeSettingsFile = "$claudeSettingsDir\settings.json"

    New-Item -ItemType Directory -Force -Path $claudeSettingsDir | Out-Null

    $injectHook = "$worklogRoot\hooks\windows\hook_context_inject.ps1"
    $stopHook   = "$worklogRoot\hooks\windows\hook_session_log.ps1"

    $injectCmd = "powershell -NonInteractive -File `"$injectHook`""
    $stopCmd   = "powershell -NonInteractive -File `"$stopHook`""

    if (Test-Path $claudeSettingsFile) {
        try {
            $settings = Get-Content $claudeSettingsFile -Raw -Encoding utf8 | ConvertFrom-Json
        } catch {
            Write-Host "      WARNING: could not parse existing settings.json. Creating backup." -ForegroundColor Yellow
            Copy-Item $claudeSettingsFile "$claudeSettingsFile.bak"
            $settings = [pscustomobject]@{}
        }
    } else {
        $settings = [pscustomobject]@{}
    }

    if (-not $settings.hooks) {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $settings.hooks | Add-Member -NotePropertyName UserPromptSubmit -NotePropertyValue @(
        [pscustomobject]@{
            hooks = @(
                [pscustomobject]@{ type = "command"; command = $injectCmd }
            )
        }
    ) -Force

    $settings.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @(
        [pscustomobject]@{
            hooks = @(
                [pscustomobject]@{ type = "command"; command = $stopCmd }
            )
        }
    ) -Force

    $settings | ConvertTo-Json -Depth 10 | Set-Content $claudeSettingsFile -Encoding utf8
    Write-Host "      Hooks written to: $claudeSettingsFile" -ForegroundColor Green
    Write-Host "      WARNING: this applies to every Claude Code project on this machine." -ForegroundColor Yellow
}

# 3. Create initial tracking files
Write-Host "[3/4] Creating tracking files..." -ForegroundColor Yellow

$activeFile  = "$worklogRoot\active_demands.txt"
$currentFile = "$worklogRoot\current_demand.txt"

$activeExisted  = Test-Path $activeFile
$currentExisted = Test-Path $currentFile

if (-not $activeExisted)  { New-Item -ItemType File -Path $activeFile  -Force | Out-Null }
if (-not $currentExisted) { New-Item -ItemType File -Path $currentFile -Force | Out-Null }

if ($activeExisted -and $currentExisted) {
    Write-Host "      active_demands.txt and current_demand.txt already exist. Skipping." -ForegroundColor DarkGray
} else {
    Write-Host "      active_demands.txt and current_demand.txt created." -ForegroundColor Green
}

# 4. Copy repos.conf.example if repos.conf doesn't exist
Write-Host "[4/4] Checking repos.conf..." -ForegroundColor Yellow

$reposConf    = "$worklogRoot\repos.conf"
$reposExample = "$worklogRoot\repos.conf.example"

if (Test-Path $reposConf) {
    Write-Host "      repos.conf already exists. Skipping." -ForegroundColor DarkGray
} else {
    Copy-Item $reposExample $reposConf
    Write-Host "      repos.conf created from example. Edit it to add your repositories." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Setup complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Restart your terminal (or run: . `$PROFILE) to load WORKLOG_PATH"
Write-Host "  2. Edit repos.conf and add your project repositories (used for diffs / day-report,"
Write-Host "       not for opening Claude there)"
Write-Host "  3. Create your first demand:"
Write-Host "       .\scripts\new-demand.ps1 -ticket `"PROJ-001`" -name `"My first demand`""
Write-Host "  4. cd here and open Claude: claude"
Write-Host "       Claude reads/edits your other repos via absolute paths from this session."
if (-not $Global) {
    Write-Host "       (Prefer opening Claude directly inside each repo instead? Run: .\setup.ps1 -Global)"
}
Write-Host ""
Write-Host "See ONBOARDING.md for detailed instructions."
Write-Host ""
