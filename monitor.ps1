$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$QueueFile = "$ScriptDir\queue.json"

$Repos = @(
    [PSCustomObject]@{ repo = "tummyslyunopened/config";              path = "." },
    [PSCustomObject]@{ repo = "tummyslyunopened/config-manager";      path = "config-manager" },
    [PSCustomObject]@{ repo = "tummyslyunopened/themes";              path = "themes" },
    [PSCustomObject]@{ repo = "tummyslyunopened/fonts";               path = "fonts" },
    [PSCustomObject]@{ repo = "tummyslyunopened/wallpapers";          path = "wallpapers" },
    [PSCustomObject]@{ repo = "tummyslyunopened/images";              path = "images" },
    [PSCustomObject]@{ repo = "tummyslyunopened/config-itam";         path = "config-itam" },
    [PSCustomObject]@{ repo = "tummyslyunopened/config-itsm";         path = "config-itsm" },
    [PSCustomObject]@{ repo = "tummyslyunopened/config-auto-github";  path = "config-auto-github" }
)

$Queue = if (Test-Path $QueueFile) { @(Get-Content $QueueFile -Raw | ConvertFrom-Json) } else { @() }
$ExistingIds = @($Queue | ForEach-Object { $_.id })

$Since = (Get-Date).ToUniversalTime().AddMinutes(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
$Added = 0

foreach ($R in $Repos) {
    $slug = $R.repo.Split("/")[1]

    # Open issues with no assignee and no existing PR
    try {
        $issues = @(gh issue list --repo $R.repo --state open --json number,title,body,assignees 2>$null | ConvertFrom-Json)
        foreach ($issue in $issues) {
            if ($issue.assignees.Count -gt 0) { continue }
            $id = "issue-$slug-$($issue.number)"
            if ($id -in $ExistingIds) { continue }
            $existingPR = @(gh pr list --repo $R.repo --search "closes #$($issue.number) in:body" --json number 2>$null | ConvertFrom-Json)
            if ($existingPR.Count -gt 0) { continue }

            $Queue += [PSCustomObject]@{
                id = $id; type = "new_issue"; repo = $R.repo; repoPath = $R.path
                number = $issue.number; title = $issue.title; body = $issue.body
                addedAt = (Get-Date -Format "o"); status = "pending"
            }
            $ExistingIds += $id
            $Added++
        }
    } catch {}

    # Recent issue comments
    try {
        $comments = @(gh api "repos/$($R.repo)/issues/comments?sort=created&direction=desc&per_page=50" 2>$null | ConvertFrom-Json)
        foreach ($c in $comments) {
            if ($c.created_at -le $Since) { continue }
            $id = "comment-$($c.id)"
            if ($id -in $ExistingIds) { continue }
            $issueNum = [int]($c.issue_url -replace ".*/")

            $Queue += [PSCustomObject]@{
                id = $id; type = "issue_comment"; repo = $R.repo; repoPath = $R.path
                number = $issueNum; author = $c.user.login; body = $c.body; url = $c.html_url
                addedAt = (Get-Date -Format "o"); status = "pending"
            }
            $ExistingIds += $id
            $Added++
        }
    } catch {}

    # Recent PR review comments
    try {
        $prComments = @(gh api "repos/$($R.repo)/pulls/comments?sort=created&direction=desc&per_page=50" 2>$null | ConvertFrom-Json)
        foreach ($c in $prComments) {
            if ($c.created_at -le $Since) { continue }
            $id = "prcomment-$($c.id)"
            if ($id -in $ExistingIds) { continue }
            $prNum = [int]($c.pull_request_url -replace ".*/")

            $Queue += [PSCustomObject]@{
                id = $id; type = "pr_review_comment"; repo = $R.repo; repoPath = $R.path
                number = $prNum; body = $c.body; filePath = $c.path
                addedAt = (Get-Date -Format "o"); status = "pending"
            }
            $ExistingIds += $id
            $Added++
        }
    } catch {}
}

$Queue | ConvertTo-Json -Depth 10 | Set-Content $QueueFile -Encoding utf8
Write-Host "Monitor: +$Added item(s). Pending: $(@($Queue | Where-Object { $_.status -eq 'pending' }).Count). Total: $($Queue.Count)."

# Start worker if there are pending items and it is not already running
$pending = @($Queue | Where-Object { $_.status -eq "pending" })
if ($pending.Count -gt 0) {
    $task = Get-ScheduledTask -TaskName "config-auto-github-worker" -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne "Running") {
        Start-ScheduledTask -TaskName "config-auto-github-worker"
        Write-Host "Monitor: started worker."
    }
}
