$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

# Monitor — polls GitHub every 5 minutes, adds items to queue, starts worker when needed
$monitorAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$ScriptDir\monitor.ps1`"" `
    -WorkingDirectory $RepoRoot

$monitorTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)

$monitorSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

Register-ScheduledTask `
    -TaskName "config-auto-github-monitor" `
    -Action $monitorAction `
    -Trigger $monitorTrigger `
    -Settings $monitorSettings `
    -RunLevel Highest `
    -Force | Out-Null

# Worker — started on demand by the monitor, loops until queue is empty
$workerAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -File `"$ScriptDir\worker.ps1`"" `
    -WorkingDirectory $RepoRoot

$workerSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

Register-ScheduledTask `
    -TaskName "config-auto-github-worker" `
    -Action $workerAction `
    -Settings $workerSettings `
    -RunLevel Highest `
    -Force | Out-Null

Write-Host "Installed:"
Write-Host "  config-auto-github-monitor   polls every 5 min, populates queue"
Write-Host "  config-auto-github-worker    started by monitor, runs until queue empty"
Write-Host ""
Write-Host "Commands:"
Write-Host "  Start monitor now:  Start-ScheduledTask -TaskName 'config-auto-github-monitor'"
Write-Host "  Start worker now:   Start-ScheduledTask -TaskName 'config-auto-github-worker'"
Write-Host "  View queue:         Get-Content '$ScriptDir\queue.json' | ConvertFrom-Json | Format-Table id,type,status"
Write-Host "  Uninstall:          .\uninstall.ps1"
