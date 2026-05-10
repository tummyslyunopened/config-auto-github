# Send a question to the designer via Telegram and block up to TimeoutSec waiting
# for a quoted-reply (long-press the bot's message and reply on the phone).
# Prints the reply text on stdout, exits 0 on success.
# On timeout: prints nothing, exits 124 (matches GNU `timeout`).
#
# This script is the ONLY path through which inbound designer text can reach
# claude. The reply has been validated by telegram-poll.ps1's security filter
# before this script returns it.

param(
    [Parameter(Mandatory)] [string] $Question,
    [int] $TimeoutSec = 300,
    [int] $PollIntervalSec = 5
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib-telegram.ps1"

try {
    $cfg = Get-TgConfig $ScriptDir
} catch {
    Write-Error $_.Exception.Message
    exit 2
}

# Correlation tag (purely cosmetic -- correlation is by message_id, not by tag)
$qid    = [guid]::NewGuid().ToString("N").Substring(0, 8)
$tagged = "[Q:$qid] $Question"

# Send via the existing static helper -- captures messageId from stdout.
$sendOut = & "$ScriptDir\telegram-send.ps1" -Body $tagged -Kind "question"
if ($LASTEXITCODE -ne 0 -or -not $sendOut) {
    Write-Error "telegram-send failed"
    exit 3
}
$msgId = [long]([string]$sendOut).Trim()

# Add to pending-questions.json
[array]$pending = Read-TgPending $cfg
$entry = [PSCustomObject]@{
    qid             = $qid
    asked_at        = (Get-Date -Format "o")
    sent_message_id = $msgId
    expires_at      = (Get-Date).AddSeconds($TimeoutSec).ToString("o")
    question        = $Question
}
$pending = @($pending) + @($entry)
Write-TgPending -Cfg $cfg -Pending $pending

# Poll loop. Each tick: drain inbox via telegram-poll, then re-read pending and
# check if our entry is now answered.
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSec

    & "$ScriptDir\telegram-poll.ps1" 2>$null | Out-Null

    [array]$pending = Read-TgPending $cfg
    $ours = $pending | Where-Object { $_.qid -eq $qid }
    if ($ours -and $ours.reply_text) {
        # Hand back the reply, then remove our entry from pending
        Write-Output ([string]$ours.reply_text)
        $pending = @($pending | Where-Object { $_.qid -ne $qid })
        Write-TgPending -Cfg $cfg -Pending $pending
        exit 0
    }
}

# Timeout. Remove our entry and exit 124.
[array]$pending = Read-TgPending $cfg
$pending = @($pending | Where-Object { $_.qid -ne $qid })
Write-TgPending -Cfg $cfg -Pending $pending
exit 124