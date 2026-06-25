<#
.SYNOPSIS
    Automated setup for claude-worklog.
    Sets WORKLOG_PATH in your PowerShell profile, configures hooks in ~/.claude/settings.json,
    and creates initial tracking files.

.EXAMPLE
    .\setup.ps1
#>

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

# 2. Configure hooks in ~/.claude/settings.json
Write-Host "[2/4] Configuring Claude Code hooks..." -ForegroundColor Yellow

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

# 3. Create initial tracking files
Write-Host "[3/4] Creating tracking files..." -ForegroundColor Yellow

$activeFile  = "$worklogRoot\active_demands.txt"
$currentFile = "$worklogRoot\current_demand.txt"

if (-not (Test-Path $activeFile))  { New-Item -ItemType File -Path $activeFile  -Force | Out-Null }
if (-not (Test-Path $currentFile)) { New-Item -ItemType File -Path $currentFile -Force | Out-Null }

Write-Host "      active_demands.txt and current_demand.txt created." -ForegroundColor Green

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
Write-Host "  2. Edit repos.conf and add your project repositories"
Write-Host "  3. Create your first demand:"
Write-Host "       .\scripts\new-demand.ps1 -ticket `"PROJ-001`" -name `"My first demand`""
Write-Host "  4. Open Claude: claude"
Write-Host ""
Write-Host "See ONBOARDING.md for detailed instructions."
Write-Host ""
