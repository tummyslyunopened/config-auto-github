# Shared logging, notification, and repo-discovery helpers.
# Dot-source this from monitor.ps1, worker.ps1, bump-sweep.ps1, merge-guide.ps1.

$LogFile = "$ScriptDir\logs\main.log"

# Discover which repos the bot watches. The parent is always included.
# Submodules are picked up from $ConfigRoot\.gitmodules; only tummyslyunopened/*
# remotes are eligible, and the bot's own repo (config-auto-github) is excluded
# so it can never modify its own scripts.
function Get-CagWatchedRepos {
    param([Parameter(Mandatory)] [string] $ConfigRoot)
    $list = @()
    $list += [PSCustomObject]@{ repo = "tummyslyunopened/config"; path = "." }

    $gm = Join-Path $ConfigRoot ".gitmodules"
    if (-not (Test-Path $gm)) { return $list }

    $currentPath = $null
    foreach ($line in Get-Content $gm) {
        $t = $line.Trim()
        if ($t -match '^path\s*=\s*(.+)$') {
            $currentPath = $matches[1].Trim()
            continue
        }
        if ($t -match '^url\s*=\s*(.+)$' -and $currentPath) {
            $url = ($matches[1].Trim()) -replace '\.git$', ''
            $slug = $null
            if     ($url -match '^github:(.+)$')              { $slug = $matches[1] }
            elseif ($url -match '^https://github\.com/(.+)$') { $slug = $matches[1] }
            elseif ($url -match '^git@github\.com:(.+)$')     { $slug = $matches[1] }
            if ($slug -and $slug -like 'tummyslyunopened/*' -and $slug -ne 'tummyslyunopened/config-auto-github') {
                $list += [PSCustomObject]@{ repo = $slug; path = $currentPath }
            }
            $currentPath = $null
        }
    }
    return $list
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    $null = New-Item -ItemType Directory -Force -Path "$ScriptDir\logs"
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    if ($script:LogSource) {
        Add-Content -Path "$ScriptDir\logs\$($script:LogSource).log" -Value $line -Encoding utf8
    }
}

function Send-Toast {
    param([string]$Title, [string]$Body)
    try {
        $xml = [xml]"<toast><visual><binding template='ToastGeneric'><text>$([System.Security.SecurityElement]::Escape($Title))</text><text>$([System.Security.SecurityElement]::Escape($Body))</text></binding></visual></toast>"
        $XmlDoc = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]::new()
        $XmlDoc.LoadXml($xml.OuterXml)
        $toast = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]::new($XmlDoc)
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::CreateToastNotifier("config-auto-github").Show($toast)
    } catch {}
}
