# Shared logging and notification helpers — dot-source this from monitor.ps1 and worker.ps1

$LogFile = "$ScriptDir\logs\main.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    $null = New-Item -ItemType Directory -Force -Path "$ScriptDir\logs"
    Add-Content -Path $LogFile -Value $line -Encoding utf8
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
