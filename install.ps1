$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunScript = "$ScriptDir\run.ps1"
$RepoRoot = Split-Path -Parent $ScriptDir

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$RunScript`"" `
    -WorkingDirectory $RepoRoot

$Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 1) -Once -At (Get-Date)

$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

Register-ScheduledTask `
    -TaskName "config-auto-github" `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -RunLevel Highest `
    -Force

Write-Host "Installed: config-auto-github runs hourly via Task Scheduler."
Write-Host "To run immediately: Start-ScheduledTask -TaskName 'config-auto-github'"
Write-Host "To uninstall: .\uninstall.ps1"
