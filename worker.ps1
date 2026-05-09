$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$QueueFile = "$ScriptDir\queue.json"
$Guidelines = if (Test-Path "$ScriptDir\guidelines.md") { Get-Content "$ScriptDir\guidelines.md" -Raw } else { "" }

. "$ScriptDir\lib.ps1"

# Prevent git, gh, and ssh from blocking on interactive prompts
$env:GIT_TERMINAL_PROMPT  = "0"   # git: never ask for credentials
$env:GIT_EDITOR           = "true" # git: no-op editor so commit/rebase never open vim
$env:GH_PROMPT_DISABLED   = "1"   # gh: disable interactive prompts
$env:SSH_ASKPASS          = ""     # suppress SSH passphrase GUI
$env:GCM_INTERACTIVE      = "never" # git credential manager: non-interactive

$TimeoutSeconds = 1800  # hard kill per item after 30 minutes

Set-Location $RepoRoot
Write-Log "Worker started. Syncing submodules..."
git submodule update --init --recursive 2>$null

while ($true) {
    if (-not (Test-Path $QueueFile)) { break }

    $Queue = @(Get-Content $QueueFile -Raw | ConvertFrom-Json)
    $Next = $Queue | Where-Object { $_.status -eq "pending" } | Select-Object -First 1
    if (-not $Next) { break }

    # Mark in-progress with start time
    $startTime = Get-Date
    $TranscriptFile = "$ScriptDir\logs\$($Next.id).log"
    $Queue | Where-Object { $_.id -eq $Next.id } | ForEach-Object {
        $_.status = "in_progress"
        $_.startedAt = $startTime.ToString("o")
        $_.transcript = $TranscriptFile
    }
    $Queue | ConvertTo-Json -Depth 10 | Set-Content $QueueFile -Encoding utf8

    Write-Log "Starting: $($Next.id) [$($Next.type)] — $($Next.repo)#$($Next.number)"
    Send-Toast "Working on $($Next.type)" "$($Next.repo) #$($Next.number) — transcript: logs\$($Next.id).log"

    $pathNote      = if ($Next.repoPath -eq ".") { "the repo root (.)" } else { "the submodule at ./$($Next.repoPath)" }
    $cdStep        = if ($Next.repoPath -ne ".") { "cd $($Next.repoPath)" } else { "# already at repo root" }
    $submoduleStep = if ($Next.repoPath -ne ".") {
        "cd $RepoRoot && git add $($Next.repoPath) && git commit -m 'chore: update $($Next.repoPath) submodule' && git push"
    } else { "" }

    $Prompt = switch ($Next.type) {
        "new_issue" {
@"
Work on GitHub issue #$($Next.number) in $($Next.repo).
The repo is checked out at $pathNote (your working directory is the config repo root).

Issue title: $($Next.title)
Issue body:
$($Next.body)

Steps:
1. $cdStep
2. gh issue edit $($Next.number) --repo $($Next.repo) --add-assignee "@me"
3. git checkout -b fix/issue-$($Next.number)-<short-slug>
4. Explore the codebase and implement a complete, correct fix
5. Stage files explicitly (no git add -A), commit, push
6. gh pr create --repo $($Next.repo) --title "fix: $($Next.title)" --body "Closes #$($Next.number)`n`n## Summary`n<what changed>"
$submoduleStep

$Guidelines
"@
        }
        "issue_comment" {
@"
Respond to a comment on GitHub issue #$($Next.number) in $($Next.repo).
The repo is checked out at $pathNote (your working directory is the config repo root).

Comment by $($Next.author):
$($Next.body)

Steps:
1. gh issue view $($Next.number) --repo $($Next.repo) --comments   # read full thread first
2. Determine what is needed:
   - Question          -> gh issue comment $($Next.number) --repo $($Next.repo) --body "..."
   - Instruction       -> $cdStep, implement change, open/update PR, reply confirming
   - "close this" etc  -> gh issue close $($Next.number) --repo $($Next.repo)
$submoduleStep

$Guidelines
"@
        }
        "pr_review_comment" {
@"
Implement changes requested in a PR review on PR #$($Next.number) in $($Next.repo).
The repo is checked out at $pathNote (your working directory is the config repo root).

Review comment on $($Next.filePath):
$($Next.body)

Steps:
1. gh pr view $($Next.number) --repo $($Next.repo) --comments   # read all feedback
2. $cdStep
3. git fetch origin && git checkout <headRefName>
4. Implement all review feedback carefully
5. Stage explicitly, commit, push
6. gh pr comment $($Next.number) --repo $($Next.repo) --body "Addressed: <summary>"
$submoduleStep

$Guidelines
"@
        }
    }

    # Run claude, capture full transcript to log file
    $null = New-Item -ItemType Directory -Force -Path "$ScriptDir\logs"
    $header = @"
# Transcript: $($Next.id)
# Type:       $($Next.type)
# Repo:       $($Next.repo) #$($Next.number)
# Started:    $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))
# Timeout:    ${TimeoutSeconds}s
# -------------------------------------------------------

"@
    Set-Content $TranscriptFile -Value $header -Encoding utf8

    # Run in a background job so we can enforce a hard timeout
    $job = Start-Job -ScriptBlock {
        param($prompt, $transcriptFile)
        $env:GIT_TERMINAL_PROMPT = "0"
        $env:GIT_EDITOR          = "true"
        $env:GH_PROMPT_DISABLED  = "1"
        claude --print --dangerously-skip-permissions $prompt 2>&1
    } -ArgumentList $Prompt, $TranscriptFile

    $completed = Wait-Job $job -Timeout $TimeoutSeconds

    if ($completed) {
        Receive-Job $job | Tee-Object -FilePath $TranscriptFile -Append
        $exitStatus = if ($job.State -eq "Failed") { "error" } else { "done" }
        if ($job.State -eq "Failed") {
            $err = $job.ChildJobs[0].JobStateInfo.Reason.Message
            Write-Log "Job failed for $($Next.id): $err" "ERROR"
            Add-Content $TranscriptFile -Value "`n[JOB FAILED] $err" -Encoding utf8
        }
    } else {
        Stop-Job $job
        $exitStatus = "timeout"
        $msg = "Timed out after ${TimeoutSeconds}s — killed."
        Write-Log $msg "ERROR"
        Add-Content $TranscriptFile -Value "`n[TIMEOUT] $msg" -Encoding utf8
        Send-Toast "claude TIMEOUT" "$($Next.id) killed after ${TimeoutSeconds}s"
    }
    Remove-Job $job -Force

    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds

    # Mark done/error (re-read in case monitor wrote to file while we ran)
    $Queue = @(Get-Content $QueueFile -Raw | ConvertFrom-Json)
    $Queue | Where-Object { $_.id -eq $Next.id } | ForEach-Object {
        $_.status = $exitStatus
        $_.completedAt = (Get-Date -Format "o")
        $_.elapsedSec = $elapsed
    }
    $Queue | ConvertTo-Json -Depth 10 | Set-Content $QueueFile -Encoding utf8

    $pendingLeft = @($Queue | Where-Object { $_.status -eq "pending" }).Count
    Write-Log "$exitStatus $($Next.id) in ${elapsed}s. $pendingLeft item(s) remaining."
    if ($exitStatus -eq "done") {
        Send-Toast "claude done: $($Next.type)" "$($Next.repo) #$($Next.number) — ${elapsed}s. $pendingLeft left."
    } elseif ($exitStatus -eq "error") {
        Send-Toast "claude ERROR: $($Next.id)" "Check logs\$($Next.id).log"
    }
}

Write-Log "Worker: queue empty, exiting."
Send-Toast "config-auto-github idle" "Queue empty — waiting for next monitor run."
