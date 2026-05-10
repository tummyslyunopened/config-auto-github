# Handle a /issue command from the designer.
#
# Strategy:
#
#   1. Try strict regex "<repo>: <title>\n<optional body>". If repo is valid,
#      create the issue immediately (no extra round-trip).
#
#   2. Otherwise invoke claude (haiku-4-5) to extract {repo, title, body}.
#
#   3. If the resolved repo is unclear (no claude match, claude declined to
#      pick, or claude picked a non-watched repo) -> reach back to the
#      designer via telegram-ask with a NUMBERED LIST of watched repos.
#      Designer long-presses the bot's question and replies with just a
#      number. Whichever they pick becomes the repo.
#
#   4. If a title is missing, use the first 80 chars of the request as a
#      fallback title. The designer can clean it up on GitHub.
#
#   5. Create the issue via `gh issue create --body-file <tempfile>` so the
#      body never trips PowerShell's empty-arg stripping.
#
# Exit codes: 0 = created, 1 = aborted (already messaged user), 2 = config error.

param(
    [Parameter(Mandatory)] [string] $Body
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
. "$ScriptDir\lib-telegram.ps1"

try { $cfg = Get-TgConfig $ScriptDir } catch { Write-Error $_.Exception.Message; exit 2 }

function Send-Reply { param([string]$Text)
    $null = & "$ScriptDir\telegram-send.ps1" -Body $Text -Kind "command-reply" 2>$null
}

function Get-WatchedShortNames {
    $gm = Join-Path $RepoRoot ".gitmodules"
    $shortNames = @("config")
    if (-not (Test-Path $gm)) { return $shortNames }
    $currentPath = $null
    foreach ($line in (Get-Content $gm)) {
        $t = $line.Trim()
        if     ($t -match '^path\s*=\s*(.+)$') { $currentPath = $matches[1].Trim() }
        elseif ($t -match '^url\s*=\s*(.+)$' -and $currentPath) {
            $url  = ($matches[1].Trim()) -replace '\.git$', ''
            $slug = $null
            if     ($url -match '^github:(.+)$')              { $slug = $matches[1] }
            elseif ($url -match '^https://github\.com/(.+)$') { $slug = $matches[1] }
            elseif ($url -match '^git@github\.com:(.+)$')     { $slug = $matches[1] }
            if ($slug -and $slug -like 'tummyslyunopened/*' -and $slug -ne 'tummyslyunopened/config-auto-github') {
                $shortNames += ($slug -replace '^tummyslyunopened/','')
            }
            $currentPath = $null
        }
    }
    return $shortNames
}

function Resolve-RepoShort {
    param([string]$Short, [string[]]$Available)
    if (-not $Short) { return $null }
    $exact = $Available | Where-Object { $_ -eq $Short }
    if ($exact) { return $exact[0] }
    return $null
}

function Invoke-ClaudeExtract {
    param([string]$Text, [string[]]$Available)
    $claudeExe = "C:\Users\remote\.local\bin\claude.exe"
    if (-not (Test-Path $claudeExe)) {
        $found = Get-Command claude -ErrorAction SilentlyContinue
        if ($found) { $claudeExe = $found.Source } else { return $null }
    }
    $repoList = ($Available -join ', ')
    $prompt = @"
You are extracting a GitHub issue request from a user's freeform text. The text may be casual or transcribed from voice -- loose grammar, missing punctuation, shortened repo names are all expected.

Available repo short-names (use EXACTLY one of these or empty string):
$repoList

User request:
$Text

Respond with ONLY a single line of valid JSON. No markdown. No preamble. No explanation.
{"repo":"<short-name-or-empty>","title":"<concise title, max 80 chars>","body":"<remaining detail or empty string>"}

If the user mentions a repo by a shortened or fuzzy name (e.g. "itsm" or "the ticketing app" or "config auto github remote view"), map it to the best exact match from the list. If you cannot determine which repo with reasonable confidence, set repo to empty string.
"@
    try {
        $response = & $claudeExe --print --dangerously-skip-permissions --model claude-haiku-4-5-20251001 $prompt 2>&1
        $jsonText = ($response -join "`n")
        if ($jsonText -match '\{[^{}]*"repo"[^{}]*\}') {
            $extracted = $matches[0] | ConvertFrom-Json -ErrorAction Stop
            return $extracted
        }
        return $null
    } catch {
        return $null
    }
}

function Ask-NumberedRepo {
    # Send the designer a numbered list of watched repos and wait up to 5 min
    # for them to long-press-reply with a number. Returns the chosen short
    # name, or $null on timeout / invalid input.
    param(
        [string[]]$Candidates,
        [string]  $LeadIn
    )
    if ($Candidates.Count -eq 0) { return $null }

    $lines = @()
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        $lines += "{0,2}. {1}" -f ($i + 1), $Candidates[$i]
    }
    $question = "$LeadIn`n`nReply to this message with a number:`n" + ($lines -join "`n")

    $reply = & "$ScriptDir\telegram-ask.ps1" -Question $question -TimeoutSec 300 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if (-not $reply) { return $null }

    # Extract first integer in the reply. Voice-to-text might surround the
    # number with extra words ("number three", "3 please"), so be forgiving.
    if ([string]$reply -match '\b(\d+)\b') {
        $n = [int]$matches[1]
        if ($n -ge 1 -and $n -le $Candidates.Count) {
            return $Candidates[$n - 1]
        }
    }
    return $null
}

function Build-OrderedCandidates {
    # Put claude's best guess first (if any and valid), then everything else
    # in alphabetical order. Keeps the list familiar between requests while
    # still surfacing the bot's best guess.
    param(
        [string[]]$Available,
        [string]  $TopGuess  # may be empty / null
    )
    $sorted = $Available | Sort-Object
    if ($TopGuess -and ($sorted -contains $TopGuess)) {
        $rest = $sorted | Where-Object { $_ -ne $TopGuess }
        return @($TopGuess) + $rest
    }
    return $sorted
}

# ---- input cleanup ------------------------------------------------------
$Body = $Body.TrimEnd()
if ([string]::IsNullOrWhiteSpace($Body)) {
    Send-Reply "Send /issue <repo> <title>, or just describe what you want. Body lines optional. /help shows the repo list."
    exit 1
}

$available = Get-WatchedShortNames
$firstLine, $rest = $Body -split "`r?`n", 2
$firstLine = $firstLine.Trim()

# ---- strategy 1: strict regex (fast path) -------------------------------
$resolvedShort = $null
$title         = $null
$issueBody     = $null

if ($firstLine -match '^(\S+)\s*:\s*(.+)$') {
    $shortGuess = $matches[1].Trim()
    $titleGuess = $matches[2].Trim()
    $resolvedShort = Resolve-RepoShort -Short $shortGuess -Available $available
    if ($resolvedShort) {
        $title     = $titleGuess
        $issueBody = if ($rest) { $rest.Trim() } else { "" }
    }
}

# ---- strategy 2: claude extract (also captures a title/body when repo
#                                  identification fails so we can reuse them
#                                  through the numbered-list confirmation)
$claudeGuess = $null
if (-not $resolvedShort) {
    $extracted = Invoke-ClaudeExtract -Text $Body -Available $available
    if ($extracted) {
        $claudeGuess = if ($extracted.repo) { [string]$extracted.repo } else { "" }
        $claudeTitle = if ($extracted.title) { [string]$extracted.title } else { "" }
        $claudeBody  = if ($extracted.body)  { [string]$extracted.body  } else { "" }
        $resolvedShort = Resolve-RepoShort -Short $claudeGuess -Available $available
        if (-not $title) { $title = $claudeTitle }
        if (-not $issueBody) { $issueBody = $claudeBody }
    }
}

# ---- strategy 3: confirm with the designer via numbered list ------------
if (-not $resolvedShort) {
    $candidates = Build-OrderedCandidates -Available $available -TopGuess $claudeGuess
    $leadIn = if ($claudeGuess) {
        "Not sure which repo. My best guess is at the top. Pick one:"
    } else {
        "Which repo did you mean?"
    }
    $resolvedShort = Ask-NumberedRepo -Candidates $candidates -LeadIn $leadIn
    if (-not $resolvedShort) {
        Send-Reply "No repo chosen. Issue not created."
        exit 1
    }
}

# ---- final title fallback -----------------------------------------------
if (-not $title -or [string]::IsNullOrWhiteSpace($title)) {
    $snippet = $Body -replace '\s+', ' '
    if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0, 80).TrimEnd() + '...' }
    $title = $snippet
}
if (-not $issueBody) { $issueBody = "" }

$fullSlug = "tummyslyunopened/$resolvedShort"

# ---- create issue -------------------------------------------------------
$tempBody = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($tempBody, $issueBody, [System.Text.UTF8Encoding]::new($false))
    $output = & gh issue create --repo $fullSlug --title $title --body-file $tempBody 2>&1
    if ($LASTEXITCODE -ne 0) {
        $err = ($output -join " ").Trim()
        Send-Reply "gh issue create failed for $fullSlug. $err"
        exit 1
    }
    $url = ($output | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1)
    if (-not $url) { $url = ($output | Select-Object -Last 1) }
    $url = ([string]$url).Trim()
} catch {
    Send-Reply "gh issue create threw: $($_.Exception.Message)"
    exit 1
} finally {
    Remove-Item $tempBody -Force -ErrorAction SilentlyContinue
}

Send-Reply "Created issue in $fullSlug`n  $title`n  $url"
exit 0