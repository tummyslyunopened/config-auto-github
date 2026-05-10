# Fire-and-forget Telegram notification.
# Usage:  telegram-send.ps1 -Body "text"  [-Kind notification|question]
# Prints the new message_id on stdout. Exit 0 on success, non-zero on failure.

param(
    [Parameter(Mandatory)] [string] $Body,
    [string] $Kind = "notification"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib-telegram.ps1"

try {
    $cfg = Get-TgConfig $ScriptDir
} catch {
    Write-Error $_.Exception.Message
    exit 2
}

$payload = @{
    chat_id = $cfg.ChatId
    text    = $Body
} | ConvertTo-Json -Compress

try {
    $resp = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($cfg.Token)/sendMessage" `
        -Method Post -Body $payload -ContentType "application/json" -ErrorAction Stop
} catch {
    Write-Error "telegram send failed: $($_.Exception.Message)"
    exit 3
}

if (-not $resp.ok) {
    Write-Error "telegram returned not-ok"
    exit 4
}

$messageId = $resp.result.message_id

Append-TgLog -Path $cfg.SentLog -Entry @{
    sent_at    = (Get-Date -Format "o")
    kind       = $Kind
    chat_id    = $cfg.ChatId
    message_id = $messageId
    body       = $Body
}

Write-Output $messageId
exit 0