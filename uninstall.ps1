Unregister-ScheduledTask -TaskName "config-auto-github-monitor" -Confirm:$false
Unregister-ScheduledTask -TaskName "config-auto-github-worker" -Confirm:$false
Write-Host "Uninstalled: config-auto-github tasks removed."
