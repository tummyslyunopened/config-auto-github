$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
. "$ScriptDir\lib.ps1"

$script:LogSource = "monitor"

# Write a PID file so config-auto-github-remote-view can detect us. Cleanup
# is best-effort; the viewer falls back to psutil to spot stale PIDs.
$PidFile = "$ScriptDir\monitor.pid"
[System.IO.File]::WriteAllText($PidFile, [string]$PID)

$QueueFile = "$ScriptDir\queue.json"

# Only activity from these GitHub usernames will ever be queued.
# Add collaborators here if you want to grant them bot access.
$AllowedAuthors = @(
    "tummyslyunopened"
)

# Build the watched-repo list dynamically from the parent's .gitmodules so that
# adding a new submodule to tummyslyunopened/config picks it up automatically on
# the next monitor run, no edits to this script required. The parent itself is
# always included; config-auto-github is always excluded (the bot must not
# modify its own scripts); non-tummyslyunopened submodules are skipped.
function Get-CagWatchedRepos {
    param([string]$ConfigRoot)
    $list = @()
    # Parent is always watched.
    $list += [PSCustomObject]@{ repo = "tummyslyunopened/config"; path = "." }

    $gm = Join-Path $ConfigRoot ".gitmodules"
    if (-not (Test-Path $gm)) {
        Write-Log "no .gitmodules at $gm -- watching parent only" "WARN"
        return $list
    }

    $currentPath = $null
    foreach ($line in (Get-Content $gm)) {
        $t = $line.Trim()
        if ($t -match '^path\s*=\s*(.+)$') {
            $currentPath = $matches[1].Trim()
            continue
        }
        if ($t -match '^url\s*=\s*(.+)$' -and $currentPath) {
            $url  = ($matches[1].Trim()) -replace '\.git$', ''
            $slug = $null
            if     ($url -match '^github:(.+)$')              { $slug = $matches[1] }
            elseif ($url -match '^https://github\.com/(.+)$') { $slug = $matches[1] }
            elseif ($url -match '^git@github\.com:(.+)$')     { $slug = $matches[1] }
            if ($slug -and $slug -like 'tummyslyunopened/*' -and $slug -ne 'tummyslyunopened/config-auto-github') {
                $list += [PSCustomObject]@{ repo = $slug; path = $currentPath }
            }
            $currentPath = $null
        }
    }
    return $list
}

[array]$Repos = Get-CagWatchedRepos -ConfigRoot $RepoRoot

function Test-AllowedAuthor {
    param([string]$Login, [string]$Context)
    if ($Login -in $AllowedAuthors) { return $true }
    Write-Log "SKIPPED [$Context] author='$Login'" "WARN"
    return $false
}

[array]$Queue = if (Test-Path $QueueFile) {
    Get-Content $QueueFile -Raw | ConvertFrom-Json | Where-Object { $_ -ne $null }
} else { @() }
[array]$ExistingIds = $Queue | ForEach-Object { $_.id }

$Since = (Get-Date).ToUniversalTime().AddMinutes(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
$Added = 0

# Load IDs of comments the bot itself posted in prior runs (recorded by
# claude-runner.ps1 from gh's stdout). We skip these on the way back in
# so the bot does not loop on its own confirmation messages. Empty set
# if the file is missing or unreadable (cold-start safe).
$OutgoingCommentsFile = "$ScriptDir\.data\outgoing-comments.jsonl"
$OutgoingIssueCommentIds   = [System.Collections.Generic.HashSet[long]]::new()
$OutgoingPrReviewCommentIds = [System.Collections.Generic.HashSet[long]]::new()
if (Test-Path $OutgoingCommentsFile) {
    foreach ($line in (Get-Content $OutgoingCommentsFile)) {
        try {
            $e = $line | ConvertFrom-Json
            switch ($e.kind) {
                "issue_comment"     { [void]$OutgoingIssueCommentIds.Add([long]$e.id) }
                "pr_review_comment" { [void]$OutgoingPrReviewCommentIds.Add([long]$e.id) }
            }
        } catch {}
    }
}
Write-Log "Monitor: $($OutgoingIssueCommentIds.Count) prior issue-comment IDs and $($OutgoingPrReviewCommentIds.Count) PR-review-comment IDs loaded for self-filter."
Write-Log "Monitor run started. Checking $($Repos.Count) repos since $Since. Allowlist: $($AllowedAuthors -join ', ')."

foreach ($R in $Repos) {
    $slug = $R.repo.Split("/")[1]

    # Open issues
    try {
        [array]$issues = gh issue list --repo $R.repo --state open --json number,title,body,assignees,author 2>$null | ConvertFrom-Json | Where-Object { $_ -ne $null }
        Write-Log "[$slug] issues: $($issues.Count) open"
        foreach ($issue in $issues) {
            if (-not $issue.number) { Write-Log "[$slug] skipping phantom issue (empty number/author)" "WARN"; continue }
            $login = $issue.author.login
            Write-Log "[$slug] issue #$($issue.number) author='$login' assignees=$($issue.assignees.Count)"
            if (-not (Test-AllowedAuthor $login "issue #$($issue.number) in $slug")) { continue }
            if ($issue.assignees.Count -gt 0) { Write-Log "[$slug] issue #$($issue.number) skipped - already assigned"; continue }
            $id = "issue-$slug-$($issue.number)"
            if ($id -in $ExistingIds) { Write-Log "[$slug] $id already in queue (status=$(($Queue | Where-Object {$_.id -eq $id}).status))"; continue }
            [array]$existingPR = gh pr list --repo $R.repo --search "closes #$($issue.number) in:body" --json number 2>$null | ConvertFrom-Json | Where-Object { $_ -ne $null }
            if ($existingPR.Count -gt 0) { Write-Log "[$slug] issue #$($issue.number) skipped - PR exists"; continue }

            $Queue += [PSCustomObject]@{
                id = $id; type = "new_issue"; repo = $R.repo; repoPath = $R.path
                number = $issue.number; title = $issue.title; body = $issue.body; author = $login
                addedAt = (Get-Date -Format "o"); status = "pending"; transcript = ""
            }
            $ExistingIds += $id; $Added++
            Write-Log "[$slug] QUEUED new_issue: $id - '$($issue.title)'"
        }
    } catch { Write-Log "[$slug] ERROR fetching issues: $_" "ERROR" }

    # Issue comments
    try {
        $apiUrl  = "repos/$($R.repo)/issues/comments"
        $params  = "sort=created&direction=desc&per_page=50"
        [array]$comments = gh api "${apiUrl}?${params}" 2>$null | ConvertFrom-Json | Where-Object { $_ -ne $null }
        $recent  = @($comments | Where-Object { $_.created_at -gt $Since })
        Write-Log "[$slug] issue comments: $($comments.Count) total, $($recent.Count) since $Since"
        foreach ($c in $recent) {
            $login = $c.user.login; $type = $c.user.type
            Write-Log "[$slug] comment id=$($c.id) login='$login' type='$type' created=$($c.created_at)"
            if (-not (Test-AllowedAuthor $login "issue-comment $($c.id) in $slug")) { continue }
            if ($OutgoingIssueCommentIds.Contains([long]$c.id)) {
                Write-Log "[$slug] comment $($c.id) skipped -- bot posted it (outgoing-id self-filter)"
                continue
            }
            $id = "comment-$($c.id)"
            if ($id -in $ExistingIds) { continue }
            $issueNum = [int]($c.issue_url -replace ".*/")
            $Queue += [PSCustomObject]@{
                id = $id; type = "issue_comment"; repo = $R.repo; repoPath = $R.path
                number = $issueNum; author = $login; body = $c.body; url = $c.html_url
                addedAt = (Get-Date -Format "o"); status = "pending"; transcript = ""
            }
            $ExistingIds += $id; $Added++
            Write-Log "[$slug] QUEUED issue_comment: $id by $login on #$issueNum"
        }
    } catch { Write-Log "[$slug] ERROR fetching issue comments: $_" "ERROR" }

    # PR review comments
    try {
        $apiUrl     = "repos/$($R.repo)/pulls/comments"
        $params     = "sort=created&direction=desc&per_page=50"
        [array]$prComments = gh api "${apiUrl}?${params}" 2>$null | ConvertFrom-Json | Where-Object { $_ -ne $null }
        $recent     = @($prComments | Where-Object { $_.created_at -gt $Since })
        Write-Log "[$slug] PR review comments: $($prComments.Count) total, $($recent.Count) since $Since"
        foreach ($c in $recent) {
            $login = $c.user.login; $type = $c.user.type
            Write-Log "[$slug] pr-comment id=$($c.id) login='$login' type='$type' created=$($c.created_at)"
            if (-not (Test-AllowedAuthor $login "pr-comment $($c.id) in $slug")) { continue }
            if ($OutgoingPrReviewCommentIds.Contains([long]$c.id)) {
                Write-Log "[$slug] pr-comment $($c.id) skipped -- bot posted it (outgoing-id self-filter)"
                continue
            }
            $id = "prcomment-$($c.id)"
            if ($id -in $ExistingIds) { continue }
            $prNum = [int]($c.pull_request_url -replace ".*/")
            $Queue += [PSCustomObject]@{
                id = $id; type = "pr_review_comment"; repo = $R.repo; repoPath = $R.path
                number = $prNum; author = $login; body = $c.body; filePath = $c.path
                addedAt = (Get-Date -Format "o"); status = "pending"; transcript = ""
            }
            $ExistingIds += $id; $Added++
            Write-Log "[$slug] QUEUED pr_review_comment: $id by $login on PR #$prNum"
        }
    } catch { Write-Log "[$slug] ERROR fetching PR comments: $_" "ERROR" }
}

ConvertTo-Json -InputObject $Queue -Depth 10 | Set-Content $QueueFile -Encoding utf8
$pendingCount = @($Queue | Where-Object { $_.status -eq "pending" }).Count
Write-Log "Monitor done. +$Added queued. Pending: $pendingCount. Total: $($Queue.Count)."

if ($Added -gt 0) { Send-Toast "config-auto-github" "$Added new item(s) queued. $pendingCount pending." }

if ($pendingCount -gt 0) {
    $task = Get-ScheduledTask -TaskName "config-auto-github-worker" -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne "Running") {
        Start-ScheduledTask -TaskName "config-auto-github-worker"
        Write-Log "Monitor: started worker task."
    }
}

Remove-Item $PidFile -ErrorAction SilentlyContinue