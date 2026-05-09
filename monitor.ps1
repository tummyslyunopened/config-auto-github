$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib.ps1"

$QueueFile = "$ScriptDir\queue.json"

# Only activity from these GitHub usernames will ever be queued.
# Add collaborators here if you want to grant them bot access.
$AllowedAuthors = @(
    "tummyslyunopened"
)

# config-auto-github is intentionally excluded -- the bot must not modify its own scripts.
$Repos = @(
    [PSCustomObject]@{ repo = "tummyslyunopened/config";         path = "." },
    [PSCustomObject]@{ repo = "tummyslyunopened/config-manager"; path = "config-manager" },
    [PSCustomObject]@{ repo = "tummyslyunopened/themes";         path = "themes" },
    [PSCustomObject]@{ repo = "tummyslyunopened/fonts";          path = "fonts" },
    [PSCustomObject]@{ repo = "tummyslyunopened/wallpapers";     path = "wallpapers" },
    [PSCustomObject]@{ repo = "tummyslyunopened/images";         path = "images" },
    [PSCustomObject]@{ repo = "tummyslyunopened/config-itam";    path = "config-itam" },
    [PSCustomObject]@{ repo = "tummyslyunopened/config-itsm";    path = "config-itsm" }
)

function Test-AllowedAuthor {
    param([string]$Login, [string]$Context)
    if ($Login -in $AllowedAuthors) { return $true }
    Write-Log "SKIPPED [$Context] author='$Login'" "WARN"
    return $false
}

$Queue = if (Test-Path $QueueFile) { @(Get-Content $QueueFile -Raw | ConvertFrom-Json) } else { @() }
$ExistingIds = @($Queue | ForEach-Object { $_.id })

$Since = (Get-Date).ToUniversalTime().AddMinutes(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
$Added = 0

Write-Log "Monitor run started. Checking $($Repos.Count) repos since $Since. Allowlist: $($AllowedAuthors -join ', ')."

foreach ($R in $Repos) {
    $slug = $R.repo.Split("/")[1]

    # Open issues
    try {
        $issues = @(gh issue list --repo $R.repo --state open --json number,title,body,assignees,author 2>$null | ConvertFrom-Json)
        Write-Log "[$slug] issues: $($issues.Count) open"
        foreach ($issue in $issues) {
            if (-not $issue.number) { Write-Log "[$slug] skipping phantom issue (empty number/author)" "WARN"; continue }
            $login = $issue.author.login
            Write-Log "[$slug] issue #$($issue.number) author='$login' assignees=$($issue.assignees.Count)"
            if (-not (Test-AllowedAuthor $login "issue #$($issue.number) in $slug")) { continue }
            if ($issue.assignees.Count -gt 0) { Write-Log "[$slug] issue #$($issue.number) skipped - already assigned"; continue }
            $id = "issue-$slug-$($issue.number)"
            if ($id -in $ExistingIds) { Write-Log "[$slug] $id already in queue (status=$(($Queue | Where-Object {$_.id -eq $id}).status))"; continue }
            $existingPR = @(gh pr list --repo $R.repo --search "closes #$($issue.number) in:body" --json number 2>$null | ConvertFrom-Json)
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
        $comments = @(gh api "${apiUrl}?${params}" 2>$null | ConvertFrom-Json)
        $recent  = @($comments | Where-Object { $_.created_at -gt $Since })
        Write-Log "[$slug] issue comments: $($comments.Count) total, $($recent.Count) since $Since"
        foreach ($c in $recent) {
            $login = $c.user.login; $type = $c.user.type
            Write-Log "[$slug] comment id=$($c.id) login='$login' type='$type' created=$($c.created_at)"
            if (-not (Test-AllowedAuthor $login "issue-comment $($c.id) in $slug")) { continue }
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
        $prComments = @(gh api "${apiUrl}?${params}" 2>$null | ConvertFrom-Json)
        $recent     = @($prComments | Where-Object { $_.created_at -gt $Since })
        Write-Log "[$slug] PR review comments: $($prComments.Count) total, $($recent.Count) since $Since"
        foreach ($c in $recent) {
            $login = $c.user.login; $type = $c.user.type
            Write-Log "[$slug] pr-comment id=$($c.id) login='$login' type='$type' created=$($c.created_at)"
            if (-not (Test-AllowedAuthor $login "pr-comment $($c.id) in $slug")) { continue }
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

$Queue | ConvertTo-Json -Depth 10 | Set-Content $QueueFile -Encoding utf8
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