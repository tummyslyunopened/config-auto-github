# bump-sweep.ps1
#
# Periodic submodule drift detector. For each submodule under the parent's
# .gitmodules, fetches origin and checks whether the submodule's default
# branch (main, falling back to master) is ahead of what the parent points
# at. If any submodule has drifted, opens a single combined auto-sweep PR
# against tummyslyunopened/config that bumps every drifted pointer.
#
# Designed to be invoked at the tail of monitor.ps1. Safe to run on a
# 5-minute cadence because:
#   - it is read-only when there is no drift
#   - it skips entirely if an auto-sweep PR is already open
#   - it refuses to run unless the parent is sitting on `main`, so it
#     never piles commits onto an in-flight feature branch

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
. "$ScriptDir\lib.ps1"
$script:LogSource = "bump-sweep"

$ParentRepo = "tummyslyunopened/config"
$SweepBranchPrefix = "bump/auto-sweep-"

# Prevent git/gh from blocking on prompts; this script runs unattended.
$env:GIT_TERMINAL_PROMPT  = "0"
$env:GIT_EDITOR           = "true"
$env:GH_PROMPT_DISABLED   = "1"

Set-Location $RepoRoot

$currentBranch = (& git rev-parse --abbrev-ref HEAD 2>$null).Trim()
if ($currentBranch -ne "main") {
    Write-Log "skipped: parent on '$currentBranch', not main"
    return
}

# Skip if there is already an open auto-sweep PR. The user merges or closes
# it; only then do we open the next one. This avoids piling up PRs.
[array]$openSweeps = & gh pr list --repo $ParentRepo --state open --search "head:$SweepBranchPrefix" --json number,headRefName 2>$null |
    ConvertFrom-Json |
    Where-Object { $_ -ne $null -and $_.headRefName -like "$SweepBranchPrefix*" }
if ($openSweeps.Count -gt 0) {
    Write-Log "skipped: auto-sweep PR already open (#$($openSweeps[0].number) on $($openSweeps[0].headRefName))"
    return
}

# Fast-forward parent main so the bump branch is based on the latest tip.
& git fetch origin --quiet 2>&1 | Out-Null
& git pull --ff-only origin main --quiet 2>&1 | Out-Null

function Get-Submodules {
    $list = @()
    $gm = Join-Path $RepoRoot ".gitmodules"
    if (-not (Test-Path $gm)) { return $list }
    $current = $null
    foreach ($line in Get-Content $gm) {
        $t = $line.Trim()
        if ($t -match '^\[submodule "([^"]+)"\]') {
            if ($current) { $list += $current }
            $current = [PSCustomObject]@{ name = $matches[1]; path = $null; url = $null }
        } elseif ($t -match '^path\s*=\s*(.+)$' -and $current) {
            $current.path = $matches[1].Trim()
        } elseif ($t -match '^url\s*=\s*(.+)$' -and $current) {
            $current.url = $matches[1].Trim()
        }
    }
    if ($current) { $list += $current }
    return $list
}

$submodules = Get-Submodules
[array]$drift = @()

foreach ($sm in $submodules) {
    if (-not $sm.path) { continue }
    $smPath = Join-Path $RepoRoot $sm.path
    if (-not (Test-Path "$smPath\.git") -and -not (Test-Path $smPath)) { continue }

    Push-Location $smPath
    try {
        & git fetch origin --quiet 2>&1 | Out-Null

        $defaultBranch = $null
        foreach ($candidate in "main", "master") {
            & git rev-parse --verify "origin/$candidate" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $defaultBranch = $candidate; break }
        }
        if (-not $defaultBranch) {
            Write-Log "$($sm.path): no origin/main or origin/master, skipping" "WARN"
            continue
        }

        $tip = (& git rev-parse "origin/$defaultBranch").Trim()

        # The parent's recorded pointer for this submodule path.
        $treeEntry = (& git -C $RepoRoot ls-tree HEAD $sm.path | Out-String).Trim()
        if (-not $treeEntry) { continue }
        $parentSha = ($treeEntry -split '\s+')[2]

        if ($tip -ne $parentSha) {
            $drift += [PSCustomObject]@{
                path   = $sm.path
                branch = $defaultBranch
                from   = $parentSha
                to     = $tip
            }
        }
    } finally {
        Pop-Location
    }
}

if ($drift.Count -eq 0) {
    Write-Log "no drift detected across $($submodules.Count) submodules"
    return
}

Write-Log "drift detected in $($drift.Count) submodule(s); preparing auto-sweep PR"

$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmm")
$branch = "$SweepBranchPrefix$ts"

& git checkout -b $branch 2>&1 | Out-Null
foreach ($d in $drift) {
    $smPath = Join-Path $RepoRoot $d.path
    Push-Location $smPath
    & git checkout --detach $d.to 2>&1 | Out-Null
    Pop-Location
    & git add $d.path 2>&1 | Out-Null
}

$commitLines = @("bump submodules: auto-sweep ($($drift.Count) drifted)", "")
foreach ($d in $drift) {
    $commitLines += "  $($d.path) -> $($d.branch) @ $($d.to.Substring(0,7))"
}
$commitMsg = $commitLines -join "`n"

# Pass the commit message via a temp file to dodge any quoting weirdness
# on Windows when the body contains newlines.
$commitMsgFile = "$env:TEMP\bump-sweep-msg-$ts.txt"
[System.IO.File]::WriteAllText($commitMsgFile, $commitMsg, [System.Text.UTF8Encoding]::new($false))
& git commit -F $commitMsgFile 2>&1 | Out-Null
Remove-Item $commitMsgFile -ErrorAction SilentlyContinue

& git push -u origin $branch 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Log "push failed for $branch -- aborting auto-sweep" "ERROR"
    & git checkout main 2>&1 | Out-Null
    return
}

$bodyLines = @(
    "## Summary",
    "Automated sweep-bump of $($drift.Count) drifted submodule$(if ($drift.Count -gt 1) { 's' }).",
    "",
    "| Submodule | Branch | New SHA |",
    "|---|---|---|"
)
foreach ($d in $drift) {
    $bodyLines += "| $($d.path) | $($d.branch) | $($d.to.Substring(0,7)) |"
}
$bodyLines += ""
$bodyLines += "Opened by config-auto-github's bump-sweep. Drift is detected whenever a submodule's default branch tip is ahead of the parent's recorded pointer."
$body = $bodyLines -join "`n"

$bodyFile = "$env:TEMP\bump-sweep-body-$ts.md"
[System.IO.File]::WriteAllText($bodyFile, $body, [System.Text.UTF8Encoding]::new($false))

$prTitle = "bump submodules: auto-sweep ($($drift.Count))"
$prResult = & gh pr create --repo $ParentRepo --base main --head $branch --title $prTitle --body-file $bodyFile 2>&1
Remove-Item $bodyFile -ErrorAction SilentlyContinue

if ($LASTEXITCODE -eq 0) {
    Write-Log "opened auto-sweep PR: $prResult"
    try {
        $tgMsg = "auto-sweep bump PR opened ($($drift.Count) submodule$(if ($drift.Count -gt 1) { 's' }))"
        $null = & "$ScriptDir\telegram-send.ps1" -Body $tgMsg 2>$null
    } catch {}
} else {
    Write-Log "gh pr create failed: $prResult" "ERROR"
}

# Always return parent to main so subsequent monitor runs find a clean state.
& git checkout main 2>&1 | Out-Null
