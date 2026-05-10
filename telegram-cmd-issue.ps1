# Handle a /issue command from the designer.
#
# The handler tries two strategies in order to be friendly to voice-to-text:
#
#   1. Strict regex: "<repo>: <title>\n<optional body>". Fast path when the
#      designer types cleanly.
#
#   2. Claude-assisted extraction (haiku-4-5). On any of:
#        - regex didn't match
#        - regex matched but the repo isn't in the watched list (e.g. user
#          said "itsm" rather than "config-itsm")
#        - missing pieces
#      ...invoke claude to extract {repo, title, body} from the free-form
#      text. Cost: ~$0.001 per fallback, negligible vs the $50/mo budget.
#
# Both paths converge to the same gh issue create call. Claude is never
# given any inbound Telegram text it wasn't asked to parse here -- the
# usual reply-correlation security filter still applies to all other
# bot/claude paths.
#
# Exit codes: 0 = created, 1 = user-rejected (already messaged), 2 = config

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
    $shortNames = @("config")   # parent always available
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
You are extracting a GitHub issue from a user request. The text may be casual or transcribed from voice, so it may be loose, missing punctuation, or use shortened repo names.

Available repo short-names (use EXACTLY one of these or empty string):
$repoList

User request:
$Text

Respond with ONLY a single line of valid JSON, no markdown, no preamble, no explanation:
{"repo":"<short-name-or-empty>","title":"<concise title, max 80 chars>","body":"<remaining detail, or empty string>"}

If the user mentions a repo by a shortened or fuzzy name (e.g. "itsm" or "the ticketing app"), map it to the best exact match from the list. If you cannot determine which repo, set "repo" to empty string.
"@
    try {
        $response = & $claudeExe --print --dangerously-skip-permissions --model claude-haiku-4-5-20251001 $prompt 2>&1
        # claude may wrap with backticks or extra text; pull the first {...} blob
        $jsonText = ($response -join "`n")
        if ($jsonText -match '\{[^{}]*\}') {
            $extracted = $matches[0] | ConvertFrom-Json -ErrorAction Stop
            return $extracted
        }
        return $null
    } catch {
        return $null
    }
}

# --- input cleanup -------------------------------------------------------
$Body = $Body.TrimEnd()
if ([string]::IsNullOrWhiteSpace($Body)) {
    Send-Reply "Send /issue <repo> <title>. The body can follow on subsequent lines. /help shows the repo list."
    exit 1
}

$available = Get-WatchedShortNames
$firstLine, $rest = $Body -split "`r?`n", 2
$firstLine = $firstLine.Trim()

# --- strategy 1: strict regex --------------------------------------------
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

# --- strategy 2: claude extract (voice-to-text friendly) ----------------
if (-not $resolvedShort) {
    $extracted = Invoke-ClaudeExtract -Text $Body -Available $available
    if ($extracted) {
        $repoCandidate = if ($extracted.repo) { [string]$extracted.repo } else { "" }
        $resolvedShort = Resolve-RepoShort -Short $repoCandidate -Available $available
        if ($resolvedShort) {
            $title     = [string]$extracted.title
            $issueBody = if ($extracted.body) { [string]$extracted.body } else { "" }
        }
    }
}

# --- bail out if still no repo ------------------------------------------
if (-not $resolvedShort) {
    $list = ($available | Sort-Object) -join ', '
    Send-Reply "Could not figure out which repo. Watched repos: $list"
    exit 1
}
if (-not $title) {
    Send-Reply "Got the repo ($resolvedShort) but no usable title. Try again with a short description after the repo."
    exit 1
}

$fullSlug = "tummyslyunopened/$resolvedShort"

# --- create issue via gh, using a body file to dodge PowerShells empty-
#     argument quirk that strips bare empty strings before they reach gh.
$tempBody = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($tempBody, $issueBody, [System.Text.UTF8Encoding]::new($false))
    $output = & gh issue create --repo $fullSlug --title $title --body-file $tempBody 2>&1
    if ($LASTEXITCODE -ne 0) {
        $err = ($output -join " ").Trim()
        Send-Reply "gh issue create failed for $fullSlug. $err"
        exit 1
    }
    $url = (($output | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1)).Trim()
    if (-not $url) { $url = ($output | Select-Object -Last 1).Trim() }
} catch {
    Send-Reply "gh issue create threw: $($_.Exception.Message)"
    exit 1
} finally {
    Remove-Item $tempBody -Force -ErrorAction SilentlyContinue
}

Send-Reply "Created issue in $fullSlug`n  $title`n  $url"
exit 0