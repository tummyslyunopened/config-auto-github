Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$QueueFile  = "$ScriptDir\queue.json"
$MonPidFile = "$ScriptDir\monitor.pid"
$WrkPidFile = "$ScriptDir\worker.pid"

# Colours
$cBg     = [System.Drawing.Color]::FromArgb(20,  20,  20)
$cPanel  = [System.Drawing.Color]::FromArgb(32,  32,  32)
$cText   = [System.Drawing.Color]::FromArgb(220, 220, 220)
$cDim    = [System.Drawing.Color]::FromArgb(120, 120, 120)
$cGreen  = [System.Drawing.Color]::FromArgb(78,  201, 176)
$cBtnMon = [System.Drawing.Color]::FromArgb(0,   100, 160)
$cBtnWrk = [System.Drawing.Color]::FromArgb(30,  110, 60)

$fMono   = New-Object System.Drawing.Font("Consolas", 11)
$fUi     = New-Object System.Drawing.Font("Segoe UI", 11)
$fUiBold = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$fBtn    = New-Object System.Drawing.Font("Segoe UI", 13)

# State
$script:MonitorProc        = $null
$script:WorkerProc         = $null
$script:MonitorAutoRun     = $true   # auto-armed on launch
$script:WorkerAutoRun      = $true   # auto-armed on launch
$script:LastMonitorStart   = $null
$script:MonitorIntervalSec = 300

function Test-PidAlive {
    param([string]$PidFile)
    if (-not (Test-Path $PidFile)) { return $false }
    $text = Get-Content $PidFile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $false }
    try { $cagPid = [int]($text.Trim()) } catch { return $false }
    try { $null = Get-Process -Id $cagPid -ErrorAction Stop; return $true } catch { return $false }
}

function Start-MonitorRun {
    $script:LastMonitorStart = Get-Date
    $script:MonitorProc = Start-Process "powershell.exe" `
        -ArgumentList "-NonInteractive -File `"$ScriptDir\monitor.ps1`"" `
        -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden
}

function Start-WorkerRun {
    $script:WorkerProc = Start-Process "powershell.exe" `
        -ArgumentList "-NonInteractive -File `"$ScriptDir\worker.ps1`"" `
        -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden
}

# Form -- compact, portrait, no transcript pane.
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "config-auto-github"
$form.ClientSize    = New-Object System.Drawing.Size(1064, 580)
$form.MinimumSize   = New-Object System.Drawing.Size(480, 480)
$form.StartPosition = "CenterScreen"
$form.BackColor     = $cBg
$form.ForeColor     = $cText

function New-Label { param($text, $x, $y, $w = 1056, $font = $fUi, $h = 28)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = $font
    $l.ForeColor = $cText
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l
}

$horizAnchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

# Title
$lblTitle = New-Label "config-auto-github" 16 12 ($form.ClientSize.Width - 32) $fUiBold 32
$lblTitle.Anchor = $horizAnchor
$form.Controls.Add($lblTitle)

# Status panel -- full width, anchored so it does not clip on narrow clients
$pnlStatus = New-Object System.Windows.Forms.Panel
$pnlStatus.Location = New-Object System.Drawing.Point(8, 56)
$pnlStatus.Size     = New-Object System.Drawing.Size(($form.ClientSize.Width - 16), 168)
$pnlStatus.Anchor   = $horizAnchor
$pnlStatus.BackColor = $cPanel
$pnlStatus.BorderStyle = "FixedSingle"
$form.Controls.Add($pnlStatus)

$innerW = $pnlStatus.ClientSize.Width - 24
$lblMonitor = New-Label "Monitor : --" 12 12  $innerW $fMono 28
$lblWorker  = New-Label "Worker  : --" 12 44  $innerW $fMono 28
$lblCounts  = New-Label ""             12 80  $innerW $fMono 28
$lblActive  = New-Label ""             12 116 $innerW $fMono 28
$lblActive.ForeColor = $cGreen
foreach ($l in @($lblMonitor, $lblWorker, $lblCounts, $lblActive)) {
    $l.Anchor = $horizAnchor
    $pnlStatus.Controls.Add($l)
}

# Two big toggle buttons -- stacked vertically full width so neither clips
# on narrow client widths or DPI-scaled displays.
$btnAnchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

$btnMon = New-Object System.Windows.Forms.Button
$btnMon.Text     = "Start Monitor"
$btnMon.Location = New-Object System.Drawing.Point(8, 244)
$btnMon.Size     = New-Object System.Drawing.Size(($form.ClientSize.Width - 16), 88)
$btnMon.Anchor   = $btnAnchor
$btnMon.BackColor = $cBtnMon
$btnMon.ForeColor = $cText
$btnMon.FlatStyle = "Flat"
$btnMon.Font     = $fBtn
$btnMon.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnMon)

$btnWrk = New-Object System.Windows.Forms.Button
$btnWrk.Text     = "Start Worker"
$btnWrk.Location = New-Object System.Drawing.Point(8, 340)
$btnWrk.Size     = New-Object System.Drawing.Size(($form.ClientSize.Width - 16), 88)
$btnWrk.Anchor   = $btnAnchor
$btnWrk.BackColor = $cBtnWrk
$btnWrk.ForeColor = $cText
$btnWrk.FlatStyle = "Flat"
$btnWrk.Font     = $fBtn
$btnWrk.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnWrk)

# Monitor interval picker
$lblIntCap = New-Label "Monitor interval:" 16 444 220 $fUi 28
$lblIntCap.ForeColor = $cDim
$form.Controls.Add($lblIntCap)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location  = New-Object System.Drawing.Point(244, 440)
$numInterval.Size      = New-Object System.Drawing.Size(96, 32)
$numInterval.Minimum   = 1
$numInterval.Maximum   = 60
$numInterval.Value     = [int]($script:MonitorIntervalSec / 60)
$numInterval.BackColor = $cPanel
$numInterval.ForeColor = $cText
$numInterval.BorderStyle = "FixedSingle"
$numInterval.Font      = $fMono
$numInterval.add_ValueChanged({
    $script:MonitorIntervalSec = [int]$numInterval.Value * 60
})
$form.Controls.Add($numInterval)

$lblIntUnit = New-Label "minutes" 350 444 120 $fUi 28
$lblIntUnit.ForeColor = $cDim
$form.Controls.Add($lblIntUnit)

# Button click handlers -- toggle auto-run on/off
$btnMon.add_Click({
    $script:MonitorAutoRun = -not $script:MonitorAutoRun
    if ($script:MonitorAutoRun -and (-not $script:MonitorProc -or $script:MonitorProc.HasExited)) {
        Start-MonitorRun
    }
    Refresh-Status
})

$btnWrk.add_Click({
    $script:WorkerAutoRun = -not $script:WorkerAutoRun
    if ($script:WorkerAutoRun -and (-not $script:WorkerProc -or $script:WorkerProc.HasExited)) {
        Start-WorkerRun
    }
    Refresh-Status
})

function Refresh-Status {
    [array]$Queue = @()
    if (Test-Path $QueueFile) {
        try { [array]$Queue = Get-Content $QueueFile -Raw | ConvertFrom-Json | Where-Object { $_ -ne $null } } catch {}
    }

    $nPending = @($Queue | Where-Object { $_.status -eq "pending"     }).Count
    $nRun     = @($Queue | Where-Object { $_.status -eq "in_progress" }).Count
    $nDone    = @($Queue | Where-Object { $_.status -eq "done"        }).Count
    $nErr     = @($Queue | Where-Object { $_.status -in @("error","timeout") }).Count
    $lblCounts.Text = "pending $nPending  |  running $nRun  |  done $nDone  |  err $nErr"

    $active = $Queue | Where-Object { $_.status -eq "in_progress" } | Select-Object -First 1
    if ($active) {
        $s = if ($active.startedAt) { [int]((Get-Date) - [datetime]$active.startedAt).TotalSeconds } else { 0 }
        $lblActive.Text = ">> $($active.id)  [${s}s]"
    } else {
        $lblActive.Text = ""
    }

    # Clear finished process handles
    if ($script:MonitorProc -and $script:MonitorProc.HasExited) { $script:MonitorProc = $null }
    if ($script:WorkerProc  -and $script:WorkerProc.HasExited)  { $script:WorkerProc  = $null }

    # Auto-rerun monitor on interval when armed
    if ($script:MonitorAutoRun -and -not $script:MonitorProc -and -not (Test-PidAlive $MonPidFile)) {
        $elapsed = if ($script:LastMonitorStart) { ((Get-Date) - $script:LastMonitorStart).TotalSeconds } else { $script:MonitorIntervalSec + 1 }
        if ($elapsed -ge $script:MonitorIntervalSec) { Start-MonitorRun }
    }

    # Auto-restart worker when armed and queue has pending work
    if ($script:WorkerAutoRun -and -not $script:WorkerProc -and -not (Test-PidAlive $WrkPidFile) -and $nPending -gt 0) {
        Start-WorkerRun
    }

    $monBusy = ($script:MonitorProc -and -not $script:MonitorProc.HasExited) -or (Test-PidAlive $MonPidFile)
    if ($script:MonitorAutoRun) {
        $btnMon.BackColor = $cGreen
        if ($monBusy) {
            $btnMon.Text = "Stop Monitor (running)"
        } else {
            $secsLeft = if ($script:LastMonitorStart) {
                [int]($script:MonitorIntervalSec - ((Get-Date) - $script:LastMonitorStart).TotalSeconds)
            } else { 0 }
            if ($secsLeft -lt 0) { $secsLeft = 0 }
            $countdown = if ($secsLeft -ge 60) { "{0}m {1:D2}s" -f [int]($secsLeft/60), ($secsLeft%60) } else { "${secsLeft}s" }
            $btnMon.Text = "Stop Monitor (next $countdown)"
        }
    } else {
        $btnMon.BackColor = $cBtnMon
        $btnMon.Text = if ($monBusy) { "Monitor running..." } else { "Start Monitor" }
    }

    $wrkBusy = ($script:WorkerProc -and -not $script:WorkerProc.HasExited) -or (Test-PidAlive $WrkPidFile)
    if ($script:WorkerAutoRun) {
        $btnWrk.BackColor = $cGreen
        $btnWrk.Text = if ($wrkBusy) { "Stop Worker (busy)" } else { "Stop Worker (idle)" }
    } else {
        $btnWrk.BackColor = $cBtnWrk
        $btnWrk.Text = if ($wrkBusy) { "Worker running..." } else { "Start Worker" }
    }

    $monStateText = if ($script:MonitorAutoRun) { if ($monBusy) { "running" } else { "armed" } } else { "off" }
    $wrkStateText = if ($script:WorkerAutoRun)  { if ($wrkBusy) { "busy"    } else { "armed" } } else { "off" }
    $lblMonitor.Text = "Monitor : $monStateText"
    $lblWorker.Text  = "Worker  : $wrkStateText"
}

# Timer
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({ Refresh-Status })
$timer.Start()

# On show: kick off both processes if they are not already running.
$form.add_Shown({
    if (-not (Test-PidAlive $MonPidFile)) { Start-MonitorRun }
    if (-not (Test-PidAlive $WrkPidFile)) { Start-WorkerRun }
    Refresh-Status
})
$form.add_FormClosed({ $timer.Stop() })

[System.Windows.Forms.Application]::Run($form)