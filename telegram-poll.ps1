# Drain the Telegram bot's inbox once and update pending-questions.json with any
# valid quoted-replies. Logs every inbound update (rejected and accepted) to
# inbox.jsonl for audit. Designed to be safe to call repeatedly from any caller
# (worker, monitor, telegram-ask).
#
# Security filter -- a message is treated as a "reply to one of our questions"
# only when ALL of these hold:
#   1. update.message.chat.id == our designer chat id
#   2. update.message.from.id == our designer chat id  (private chat: from == chat)
#   3. update.message.reply_to_message.from.id == our bot's id
#   4. update.message.reply_to_message.message_id matches an entry in
#      pending-questions.json
#   5. that entry has no reply_text yet and expires_at is still in the future
#
# Anything else is logged but never returned to a caller.

param([int] $LongPollSec = 0)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib-telegram.ps1"

try {
    $cfg = Get-TgConfig $ScriptDir
    $botId = Get-TgBotId $cfg
} catch {
    Write-Error $_.Exception.Message
    exit 2
}

$offset = if (Test-Path $cfg.OffsetFile) {
    [long]((Get-Content $cfg.OffsetFile -Raw).Trim())
} else { 0 }

$url = "https://api.telegram.org/bot$($cfg.Token)/getUpdates?offset=$offset&timeout=$LongPollSec"
try {
    $resp = Invoke-RestMethod -Uri $url -ErrorAction Stop
} catch {
    Write-Error "getUpdates failed: $($_.Exception.Message)"
    exit 3
}
if (-not $resp.ok) { Write-Error "telegram returned not-ok"; exit 4 }
$updates = @($resp.result)

[array]$pending = Read-TgPending $cfg
$now = Get-Date
$matched = 0

foreach ($u in $updates) {
    # Audit every inbound, regardless of outcome
    Append-TgLog -Path $cfg.InboxLog -Entry @{
        received_at = $now.ToString("o")
        update      = $u
    }

    $msg = $u.message
    if (-not $msg) { continue }

    # 1+2: must be in the designer's DM
    if ($msg.chat.id -ne $cfg.ChatId) { continue }
    if ($msg.from.id -ne $cfg.ChatId) { continue }

    # 3: must be a reply to our bot
    $rtm = $msg.reply_to_message
    if (-not $rtm) { continue }
    if ($rtm.from.id -ne $botId) { continue }

    # 4+5: must match a pending question still awaiting reply and not expired
    $repliedTo = [long]$rtm.message_id
    foreach ($q in $pending) {
        if ($q.sent_message_id -ne $repliedTo) { continue }
        if ($q.reply_text)                    { continue }
        try {
            if ([datetime]$q.expires_at -le $now) { continue }
        } catch { continue }

        $q | Add-Member -NotePropertyName reply_text -NotePropertyValue ([string]$msg.text) -Force
        $q | Add-Member -NotePropertyName replied_at -NotePropertyValue $now.ToString("o") -Force
        $q | Add-Member -NotePropertyName reply_message_id -NotePropertyValue ([long]$msg.message_id) -Force
        $matched++
        break
    }
}

# Second pass: dispatch slash-commands. We re-iterate the same updates so the
# reply-correlation pass stays self-contained. A message is only a command if
# it is NOT a reply (replies handled above) and the text starts with a
# recognised command token.
$commandsHandled = 0
foreach ($u in $updates) {
    $msg = $u.message
    if (-not $msg) { continue }
    if ($msg.chat.id -ne $cfg.ChatId) { continue }
    if ($msg.from.id -ne $cfg.ChatId) { continue }
    if ($msg.reply_to_message)        { continue }
    $text = [string]$msg.text
    if (-not $text) { continue }
    if ($text -match '^/issue\b\s*(.*)$') {
        # Capture everything after /issue, including any body lines on
        # subsequent newlines. The handler script parses "<repo>: <title>"
        # then optional body.
        $payload = $matches[1]
        $textLines = $text -split "`r?`n", 2
        if ($textLines.Count -gt 1) { $payload = "$($matches[1])`n$($textLines[1])" }
        & "$ScriptDir\telegram-cmd-issue.ps1" -Body $payload 2>&1 | Out-Null
        $commandsHandled++
    }
    elseif ($text -match '^/help\b') {
        & "$ScriptDir\telegram-cmd-help.ps1" 2>&1 | Out-Null
        $commandsHandled++
    }
    # Anything else: silently logged to inbox.jsonl above, no reaction.
}

# Advance the offset cursor (Telegram retains updates until acked)
if ($updates.Count -gt 0) {
    $newOffset = ($updates | Measure-Object -Property update_id -Maximum).Maximum + 1
    [System.IO.File]::WriteAllText($cfg.OffsetFile, "$newOffset", [System.Text.UTF8Encoding]::new($false))
}

# Persist pending changes (and create the file even if empty so callers can read it)
Write-TgPending -Cfg $cfg -Pending $pending

Write-Output "polled=$($updates.Count) matched_replies=$matched commands_handled=$commandsHandled"
exit 0