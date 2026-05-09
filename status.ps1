# Live queue dashboard. Run this in any terminal — refreshes every 3 seconds.
# Ctrl+C to exit.
# Optional: pass an item ID to tail its transcript instead.
#   .\status.ps1 -Tail issue-config-5

param([string]$Tail = "")

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$QueueFile = "$ScriptDir\queue.json"
$LogFile   = "$ScriptDir\logs\main.log"

if ($Tail) {
    $TranscriptFile = "$ScriptDir\logs\$Tail.log"
    if (-not (Test-Path $TranscriptFile)) {
        Write-Host "No transcript found for '$Tail'. Has the worker started it yet?"
        exit 1
    }
    Write-Host "Tailing transcript for $Tail (Ctrl+C to stop)..."
    Get-Content $TranscriptFile -Wait
    exit
}

while ($true) {
    Clear-Host

    # ── Header ──────────────────────────────────────────────────────────────
    Write-Host "config-auto-github status  $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ""

    # ── Task Scheduler state ─────────────────────────────────────────────────
    $monitor = Get-ScheduledTask -TaskName "config-auto-github-monitor" -ErrorAction SilentlyContinue
    $worker  = Get-ScheduledTask -TaskName "config-auto-github-worker"  -ErrorAction SilentlyContinue
    $mState  = if ($monitor) { $monitor.State } else { "not installed" }
    $wState  = if ($worker)  { $worker.State  } else { "not installed" }
    $mColor  = if ($mState -eq "Running") { "Green" } else { "Gray" }
    $wColor  = if ($wState -eq "Running") { "Green" } elseif ($wState -eq "Ready") { "Yellow" } else { "Gray" }

    Write-Host ("  monitor  [{0,-14}]   worker  [{1,-14}]" -f $mState, $wState)
    Write-Host ""

    # ── Queue ────────────────────────────────────────────────────────────────
    if (-not (Test-Path $QueueFile)) {
        Write-Host "  queue.json not found — monitor has not run yet." -ForegroundColor Yellow
    } else {
        $Queue = @(Get-Content $QueueFile -Raw | ConvertFrom-Json)

        $pending    = @($Queue | Where-Object { $_.status -eq "pending" })
        $inProgress = @($Queue | Where-Object { $_.status -eq "in_progress" })
        $done       = @($Queue | Where-Object { $_.status -eq "done" })
        $errors     = @($Queue | Where-Object { $_.status -eq "error" })

        Write-Host ("  pending {0}  |  in_progress {1}  |  done {2}  |  error {3}  |  total {4}" `
            -f $pending.Count, $inProgress.Count, $done.Count, $errors.Count, $Queue.Count)
        Write-Host ""

        # Currently running
        if ($inProgress.Count -gt 0) {
            $item = $inProgress[0]
            $elapsed = if ($item.startedAt) {
                $s = [int]((Get-Date) - [datetime]$item.startedAt).TotalSeconds
                "${s}s"
            } else { "?" }
            Write-Host "  RUNNING  $($item.id)" -ForegroundColor Green -NoNewline
            Write-Host "  [$elapsed elapsed]" -ForegroundColor DarkGreen
            Write-Host "           $($item.repo) #$($item.number) — $($item.type)"
            if ($item.transcript) {
                Write-Host "           transcript: $($item.transcript)" -ForegroundColor DarkCyan
                Write-Host "           tail live:  .\status.ps1 -Tail $($item.id)" -ForegroundColor DarkCyan
            }
            Write-Host ""
        }

        # Pending queue
        if ($pending.Count -gt 0) {
            Write-Host "  PENDING:" -ForegroundColor Yellow
            $pending | Select-Object -First 10 | ForEach-Object {
                Write-Host ("    {0,-45} {1}" -f $_.id, $_.repo)
            }
            if ($pending.Count -gt 10) { Write-Host "    ... and $($pending.Count - 10) more" }
            Write-Host ""
        }

        # Errors
        if ($errors.Count -gt 0) {
            Write-Host "  ERRORS:" -ForegroundColor Red
            $errors | ForEach-Object {
                Write-Host "    $($_.id)  — see logs\$($_.id).log" -ForegroundColor Red
            }
            Write-Host ""
        }

        # Recent completions
        $recent = @($done | Sort-Object completedAt -Descending | Select-Object -First 5)
        if ($recent.Count -gt 0) {
            Write-Host "  RECENTLY DONE:" -ForegroundColor DarkGray
            $recent | ForEach-Object {
                $t = if ($_.completedAt) { ([datetime]$_.completedAt).ToString("HH:mm:ss") } else { "?" }
                Write-Host ("    {0}  {1,-45} {2}s" -f $t, $_.id, $_.elapsedSec) -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }

    # ── Recent log lines ─────────────────────────────────────────────────────
    if (Test-Path $LogFile) {
        Write-Host "  RECENT LOG:" -ForegroundColor DarkGray
        Get-Content $LogFile -Tail 6 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host "  Ctrl+C to exit  |  .\status.ps1 -Tail <id>  to watch a transcript" -ForegroundColor DarkGray

    Start-Sleep 3
}
