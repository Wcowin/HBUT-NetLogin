<#
    HBUT-NetLogin installer

    Install   : powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
    Uninstall : powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
    Run now   : powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -RunNow

    Two scheduled tasks are created (needs administrator, UAC will pop up):
      CampusNetAutoLogin      - runs at logon
      CampusNetAutoLoginPoll  - runs every 5 minutes and re-logins after drops

    Without admin rights it falls back to the user's Startup folder (no admin needed).
#>
param(
    [switch]$Uninstall,
    [switch]$RunNow
)

$TaskName  = 'CampusNetAutoLogin'
$PollName  = 'CampusNetAutoLoginPoll'
$Script    = Join-Path $PSScriptRoot 'login.ps1'
$Config    = Join-Path $PSScriptRoot 'config.ps1'
$Startup   = [Environment]::GetFolderPath('Startup')
$VbsPath   = Join-Path $Startup 'CampusNetAutoLogin.vbs'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Install / Uninstall need admin rights: re-launch self elevated (UAC prompt).
# -RunNow does not need elevation, so it never triggers UAC.
if (-not $RunNow -and -not (Test-IsAdmin)) {
    $argList = @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    try {
        Write-Output 'Requesting administrator rights (click Yes on the UAC prompt)...'
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        exit 0
    } catch {
        Write-Output "[..] UAC declined or unavailable ($($_.Exception.Message)) - using the no-admin method instead"
    }
}

if ($RunNow) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script
    exit $LASTEXITCODE
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $PollName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $VbsPath) { Remove-Item $VbsPath -Force }
    Write-Output "removed: tasks '$TaskName', '$PollName' and $VbsPath"
    exit 0
}

if (-not (Test-Path $Script)) { Write-Error "login.ps1 not found: $Script"; exit 1 }
if (-not (Test-Path $Config)) {
    Write-Output 'config.ps1 not found. Copy config.example.ps1 to config.ps1 and fill in your account first.'
    exit 1
}

# ---- 1) try the scheduled tasks (requires administrator) ----
$taskOk = $false
try {
    $arg      = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    # (a) at logon: full run, patient enough to wait for the network
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $PSScriptRoot
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT20S'
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description 'Auto login to campus network (eportal) after logon' -Force -ErrorAction Stop | Out-Null

    # (b) every 5 minutes: cheap re-check, re-login after sleep resume / wifi drop / being kicked off
    $argPoll  = "$arg -Poll"
    $actionP  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argPoll -WorkingDirectory $PSScriptRoot
    $triggerP = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                    -RepetitionInterval (New-TimeSpan -Minutes 5) `
                    -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $PollName -Action $actionP -Trigger $triggerP -Settings $settings `
        -Description 'Periodic campus network re-login check (every 5 min)' -Force -ErrorAction Stop | Out-Null

    $taskOk = $true
    Write-Output "[OK] tasks registered: '$TaskName' (at logon) + '$PollName' (every 5 min)"
} catch {
    Write-Output "[..] scheduled task unavailable (needs admin): $($_.Exception.Message)"
}

# ---- 2) fallback: silent launcher in the Startup folder ----
if ($taskOk) {
    if (Test-Path $VbsPath) { Remove-Item $VbsPath -Force; Write-Output '[OK] removed duplicate Startup launcher (task covers it)' }
    if (-not $Uninstall) { exit 0 }
}

$vbs = @"
Set ws = CreateObject("WScript.Shell")
ws.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$Script""", 0, False
"@
Set-Content -LiteralPath $VbsPath -Value $vbs -Encoding ASCII
Write-Output "[OK] startup launcher created: $VbsPath"

# ---- 3) handy desktop shortcut for manual re-login ----
try {
    $desk  = [Environment]::GetFolderPath('Desktop')
    $short = Join-Path $desk 'CampusNetLogin.lnk'
    $wsh   = New-Object -ComObject WScript.Shell
    $sc    = $wsh.CreateShortcut($short)
    $sc.TargetPath       = 'powershell.exe'
    $sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" -Force"
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.Description      = 'Login campus network now'
    $sc.Save()
    Write-Output "[OK] desktop shortcut: $short"
} catch { }

if (-not $taskOk) {
    Write-Output ''
    Write-Output 'Note: running without admin, so the Startup-folder launcher is used.'
    Write-Output 'It runs at every Windows logon, silently. Test it with: install.ps1 -RunNow'
}
