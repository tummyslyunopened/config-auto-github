$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$QueueFile = "$ScriptDir\queue.json"
$Guidelines = if (Test-Path "$ScriptDir\guidelines.md") { Get-Content "$ScriptDir\guidelines.md" -Raw } else { "" }

. "$ScriptDir\lib.ps1"

$script:LogSource = "worker"

# Write a PID file so config-auto-github-remote-view can detect us. Cleanup
# is best-effort; the viewer falls back to psutil to spot stale PIDs.
$PidFile = "$ScriptDir\worker.pid"
[System.IO.File]::WriteAllText($PidFile, [string]$PID)

# Prevent git, gh, and ssh from blocking on interactive prompts
$env:GIT_TERMINAL_PROMPT  = "0"
$env:GIT_EDITOR           = "true"
$env:GH_PROMPT_DISABLED   = "1"
$env:SSH_ASKPASS          = ""
$env:GCM_INTERACTIVE      = "never"

# Resolve claude executable - may not be in PATH when launched from GUI
$ClaudeExe = "C:\Users\remote\.local\bin\claude.exe"
if (-not (Test-Path $ClaudeExe)) {
    $found = Get-Command claude -ErrorAction SilentlyContinue
    if ($found) { $ClaudeExe = $found.Source }
}
Write-Log "Claude exe: $ClaudeExe (exists: $(Test-Path $ClaudeExe))"

$TimeoutSeconds = 1800

Set-Location $RepoRoot
Write-Log "Worker started. Syncing submodules..."
git submodule update --init --recursive 2>$null

while ($true) {
    if (-not (Test-Path $QueueFile)) { break }

    [array]$Queue = Get-Content $QueueFile -Raw | ConvertFrom-Json | Where-Object { $_ -ne $null }
    $Next = $Queue | Where-Object { $_.status -eq "pending" } | Select-Object -First 1
    if (-not $Next) { break }

    $startTime = Get-Date
    $TranscriptFile = "$ScriptDir\logs\$($Next.id).log"

    $Queue | Where-Object { $_.id -eq $Next.id } | ForEach-Object {
        $_.status = "in_progress"
        $_ | Add-Member -NotePropertyName "startedAt"  -NotePropertyValue $startTime.ToString("o") -Force
        $_ | Add-Member -NotePropertyName "transcript" -NotePropertyValue $TranscriptFile -Force
    }
    ConvertTo-Json -InputObject $Queue -Depth 10 | Set-Content $QueueFile -Encoding utf8

    Write-Log "Starting: $($Next.id) [$($Next.type)] -- $($Next.repo)#$($Next.number)"
    Send-Toast "Working on $($Next.type)" "$($Next.repo) #$($Next.number)"

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
1. gh issue view $($Next.number) --repo $($Next.repo) --comments
2. Determine what is needed:
   - Question     -> gh issue comment $($Next.number) --repo $($Next.repo) --body "..."
   - Instruction  -> $cdStep, implement change, open/update PR, reply confirming
   - Close request -> gh issue close $($Next.number) --repo $($Next.repo)
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
1. gh pr view $($Next.number) --repo $($Next.repo) --comments
2. $cdStep
3. git fetch origin && git checkout <headRefName>
4. Implement all review feedback
5. Stage explicitly, commit, push
6. gh pr comment $($Next.number) --repo $($Next.repo) --body "Addressed: <summary>"
$submoduleStep

$Guidelines
"@
        }
    }

    $null = New-Item -ItemType Directory -Force -Path "$ScriptDir\logs"
    $header = "# $($Next.id) | $($Next.type) | $($Next.repo) #$($Next.number) | started $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))`n# -------------------------------------------------------`n`n"
    [System.IO.File]::WriteAllText($TranscriptFile, $header, [System.Text.UTF8Encoding]::new($false))

    # Write prompt to a temp file (avoids command-line quoting issues) and call the
    # static claude-runner.ps1 which streams stream-json events live to the transcript.
    $promptFile = "$env:TEMP\cag-prompt-$($Next.id).txt"
    [System.IO.File]::WriteAllText($promptFile, $Prompt, [System.Text.UTF8Encoding]::new($false))

    $runnerScript = "$ScriptDir\claude-runner.ps1"
    $runnerArgs = @(
        "-NonInteractive", "-NoProfile", "-File", "`"$runnerScript`"",
        "-ClaudeExe",      "`"$ClaudeExe`"",
        "-PromptFile",     "`"$promptFile`"",
        "-TranscriptFile", "`"$TranscriptFile`"",
        "-RepoRoot",       "`"$RepoRoot`""
    )
    $proc = Start-Process "powershell.exe" `
        -ArgumentList ($runnerArgs -join " ") `
        -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden

    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)

    if ($finished) {
        $exitStatus = if ($proc.ExitCode -eq 0) { "done" } else { "error" }
        if ($exitStatus -eq "error") {
            Write-Log "claude exited with code $($proc.ExitCode) for $($Next.id)" "ERROR"
            Add-Content $TranscriptFile -Value "`n[EXIT CODE $($proc.ExitCode)]" -Encoding utf8
        }
    } else {
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        $exitStatus = "timeout"
        $msg = "Timed out after ${TimeoutSeconds}s -- killed."
        Write-Log $msg "ERROR"
        Add-Content $TranscriptFile -Value "`n[TIMEOUT] $msg" -Encoding utf8
        Send-Toast "claude TIMEOUT" "$($Next.id) killed after ${TimeoutSeconds}s"
    }

    Remove-Item $promptFile -ErrorAction SilentlyContinue

    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds

    [array]$Queue = Get-Content $QueueFile -Raw | ConvertFrom-Json | Where-Object { $_ -ne $null }
    $Queue | Where-Object { $_.id -eq $Next.id } | ForEach-Object {
        $_.status = $exitStatus
        $_ | Add-Member -NotePropertyName "completedAt" -NotePropertyValue (Get-Date -Format "o") -Force
        $_ | Add-Member -NotePropertyName "elapsedSec"  -NotePropertyValue $elapsed -Force
    }
    ConvertTo-Json -InputObject $Queue -Depth 10 | Set-Content $QueueFile -Encoding utf8

    $pendingLeft = @($Queue | Where-Object { $_.status -eq "pending" }).Count
    Write-Log "$exitStatus $($Next.id) in ${elapsed}s. $pendingLeft remaining."
    if ($exitStatus -eq "done") {
        Send-Toast "claude done" "$($Next.repo) #$($Next.number) -- ${elapsed}s. $pendingLeft left."
    } elseif ($exitStatus -eq "error") {
        Send-Toast "claude ERROR" "$($Next.id) -- check logs\$($Next.id).log"
    }
}

Remove-Item $PidFile -ErrorAction SilentlyContinue
Write-Log "Worker: queue empty, exiting."
Send-Toast "config-auto-github idle" "Queue empty -- waiting for next monitor run."