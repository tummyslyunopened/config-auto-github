# Handle a single "/issue <repo>: <title>\n<body...>" command from the designer.
#
# Parses the slug + title + optional body, resolves the slug to a watched
# tummyslyunopened/* repo, runs `gh issue create`, and sends a confirmation
# message (success URL or error) back to the designer via telegram-send.ps1.
#
# This script never invokes claude. It is invoked by telegram-poll.ps1 when
# an unsolicited message starting with /issue is detected.
#
# Exit codes: 0 = created, 1 = rejected (already sent the user an error
# message), 2 = config error.

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
    # Mirrors monitor.ps1's Get-CagWatchedRepos -- read the parent .gitmodules.
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

# --- parse ---------------------------------------------------------------
$Body = $Body.TrimEnd()
if ([string]::IsNullOrWhiteSpace($Body)) {
    Send-Reply "Usage: /issue <repo>: <title>`n<body lines, optional>`n`nSend /help for the repo list."
    exit 1
}

# Split into first-line + rest
$firstLine, $rest = $Body -split "`r?`n", 2
$firstLine = $firstLine.Trim()

# First line must be "<repo>: <title>"
if ($firstLine -notmatch '^(\S+)\s*:\s*(.+)$') {
    Send-Reply "Could not parse. Expected: /issue <repo>: <title>`nGot first line: '$firstLine'"
    exit 1
}
$repoShort = $matches[1].Trim()
$title     = $matches[2].Trim()
$issueBody = if ($rest) { $rest.Trim() } else { "" }

# --- resolve repo --------------------------------------------------------
$available = Get-WatchedShortNames
$exact = $available | Where-Object { $_ -eq $repoShort }
if ($exact) {
    $resolvedShort = $exact[0]
} else {
    $prefix = $available | Where-Object { $_.StartsWith($repoShort) }
    if ($prefix.Count -eq 1) {
        $resolvedShort = $prefix[0]
    } elseif ($prefix.Count -gt 1) {
        Send-Reply "Repo '$repoShort' is ambiguous. Candidates: $($prefix -join ', '). Retry with the full short name."
        exit 1
    } else {
        $list = ($available | Sort-Object) -join ', '
        Send-Reply "Unknown repo '$repoShort'. Available:`n$list"
        exit 1
    }
}
$fullSlug = "tummyslyunopened/$resolvedShort"

# --- create issue --------------------------------------------------------
try {
    $url = if ($issueBody) {
        & gh issue create --repo $fullSlug --title $title --body $issueBody 2>&1
    } else {
        & gh issue create --repo $fullSlug --title $title --body "" 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        Send-Reply "gh issue create failed for $fullSlug -- $url"
        exit 1
    }
    $url = ($url | Select-Object -Last 1).Trim()
} catch {
    Send-Reply "gh issue create threw: $($_.Exception.Message)"
    exit 1
}

Send-Reply "Created issue in $fullSlug`n  $title`n  $url"
exit 0