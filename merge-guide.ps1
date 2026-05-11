# merge-guide.ps1
#
# Print a recommended merge order for all currently open PRs across the
# bot's watched repos. Output is plain text suitable for posting to
# Telegram or for human reading.
#
# Order is dependency-aware:
#   1. Submodule PRs first (oldest-first within group). They can be merged
#      in any order among themselves, but they must merge BEFORE the parent
#      bump that will eventually point at their main tip.
#   2. Parent (tummyslyunopened/config) PRs last. They bump submodule
#      pointers, so the corresponding submodule PRs should land first.
#
# Side-effect: writes the same text (wrapped in a tiny markdown shell) to
# <repo_root>/.data/merge-guide.md so you have a local snapshot between
# Telegram pings.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
. "$ScriptDir\lib.ps1"
$script:LogSource = "merge-guide"

$env:GIT_TERMINAL_PROMPT = "0"
$env:GH_PROMPT_DISABLED  = "1"

[array]$Repos = Get-CagWatchedRepos -ConfigRoot $RepoRoot
# Get-CagWatchedRepos excludes config-auto-github because the bot cannot
# act on its own issues. For merge ordering we DO want to see PRs against
# config-auto-github -- the designer still has to merge them.
if (-not ($Repos | Where-Object { $_.repo -eq "tummyslyunopened/config-auto-github" })) {
    $Repos += [PSCustomObject]@{ repo = "tummyslyunopened/config-auto-github"; path = "config-auto-github" }
}

[array]$submodulePrs = @()
[array]$parentPrs    = @()

foreach ($R in $Repos) {
    try {
        [array]$prs = gh pr list --repo $R.repo --state open --json number,title,createdAt,headRefName --limit 50 2>$null |
            ConvertFrom-Json |
            Where-Object { $_ -ne $null }
    } catch {
        Write-Log "failed to list PRs for $($R.repo): $_" "WARN"
        continue
    }
    foreach ($pr in $prs) {
        $entry = [PSCustomObject]@{
            repo      = $R.repo
            number    = $pr.number
            title     = $pr.title
            createdAt = $pr.createdAt
            headRef   = $pr.headRefName
        }
        if ($R.repo -eq "tummyslyunopened/config") { $parentPrs += $entry }
        else                                       { $submodulePrs += $entry }
    }
}

$submodulePrs = @($submodulePrs | Sort-Object createdAt)
$parentPrs    = @($parentPrs    | Sort-Object createdAt)

$total = $submodulePrs.Count + $parentPrs.Count
$lines = @()
if ($total -eq 0) {
    $lines += "Merge order: no open PRs."
} else {
    $lines += "Merge order ($total open):"
    $i = 1
    foreach ($pr in $submodulePrs) {
        $slug = $pr.repo.Split("/")[1]
        $lines += ("{0,2}. sub    {1}#{2} -- {3}" -f $i, $slug, $pr.number, $pr.title)
        $i++
    }
    foreach ($pr in $parentPrs) {
        $lines += ("{0,2}. parent config#{1} -- {2}" -f $i, $pr.number, $pr.title)
        $i++
    }
    if ($submodulePrs.Count -gt 0 -and $parentPrs.Count -gt 0) {
        $lines += ""
        $lines += "(merge submodule PRs first; the next bump-sweep tick refreshes parent bumps)"
    }
}
$text = $lines -join "`n"

# Snapshot to disk so the designer can open it between Telegram pings.
$dataDir = Join-Path $RepoRoot ".data"
$null = New-Item -ItemType Directory -Force -Path $dataDir
$mdPath = Join-Path $dataDir "merge-guide.md"
$ts = Get-Date -Format "o"
# Use single-quoted segments for the fence so triple-backticks survive
# PowerShell's escape parsing. ${ts} (not $ts_) prevents the underscore
# being absorbed into the variable name.
$fence = '```'
$md = "# Merge guide`n`n_Last updated ${ts}_`n`n" + $fence + "`n$text`n" + $fence + "`n"
[System.IO.File]::WriteAllText($mdPath, $md, [System.Text.UTF8Encoding]::new($false))

Write-Output $text
