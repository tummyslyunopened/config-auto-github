# Shared helpers for the Telegram static scripts. Dot-source from each.
#
# State layout (under config-auto-github/.data/telegram/, all gitignored):
#   token.txt           - bot HTTP API token
#   chat-id.txt         - the designer's chat id (numeric)
#   update-offset.txt   - next Telegram update_id to fetch (int cursor)
#   sent.jsonl          - append-only log of every outgoing message
#   inbox.jsonl         - append-only log of every inbound update (rejected and accepted)
#   pending-questions.json - active questions awaiting reply

function Get-TgConfig {
    param([Parameter(Mandatory)] [string] $ScriptDir)
    $dataDir = Join-Path $ScriptDir ".data\telegram"
    $tokenFile = Join-Path $dataDir "token.txt"
    $chatFile  = Join-Path $dataDir "chat-id.txt"
    if (-not (Test-Path $tokenFile)) { throw "missing $tokenFile" }
    if (-not (Test-Path $chatFile))  { throw "missing $chatFile" }
    [PSCustomObject]@{
        DataDir      = $dataDir
        Token        = (Get-Content $tokenFile -Raw).Trim()
        ChatId       = [long]((Get-Content $chatFile -Raw).Trim())
        OffsetFile   = Join-Path $dataDir "update-offset.txt"
        SentLog      = Join-Path $dataDir "sent.jsonl"
        InboxLog     = Join-Path $dataDir "inbox.jsonl"
        PendingFile  = Join-Path $dataDir "pending-questions.json"
        BotIdFile    = Join-Path $dataDir "bot-id.txt"
    }
}

function Get-TgBotId {
    param([Parameter(Mandatory)] [PSCustomObject] $Cfg)
    # Cached after first lookup so we do not hammer getMe.
    if (Test-Path $Cfg.BotIdFile) {
        return [long]((Get-Content $Cfg.BotIdFile -Raw).Trim())
    }
    $me = (Invoke-RestMethod "https://api.telegram.org/bot$($Cfg.Token)/getMe").result
    [System.IO.File]::WriteAllText($Cfg.BotIdFile, "$($me.id)", [System.Text.UTF8Encoding]::new($false))
    return [long]$me.id
}

function Read-TgPending {
    param([Parameter(Mandatory)] [PSCustomObject] $Cfg)
    if (-not (Test-Path $Cfg.PendingFile)) { return @() }
    try {
        [array]$p = Get-Content $Cfg.PendingFile -Raw -Encoding utf8 | ConvertFrom-Json | Where-Object { $_ -ne $null }
        return $p
    } catch {
        return @()
    }
}

function Write-TgPending {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Cfg,
        [array] $Pending
    )
    # Empty arrays serialise as "null" via ConvertTo-Json -- write [] explicitly.
    if (-not $Pending -or $Pending.Count -eq 0) {
        Set-Content -Path $Cfg.PendingFile -Value "[]" -Encoding utf8
        return
    }
    ConvertTo-Json -InputObject @($Pending) -Depth 10 | Set-Content $Cfg.PendingFile -Encoding utf8
}

function Append-TgLog {
    param([string] $Path, [object] $Entry)
    $line = $Entry | ConvertTo-Json -Compress -Depth 12
    Add-Content -Path $Path -Value $line -Encoding utf8
}