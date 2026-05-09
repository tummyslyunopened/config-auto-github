Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$QueueFile  = "$ScriptDir\queue.json"
$LogFile    = "$ScriptDir\logs\main.log"

# Colours
$cBg     = [System.Drawing.Color]::FromArgb(20,  20,  20)
$cPanel  = [System.Drawing.Color]::FromArgb(32,  32,  32)
$cBorder = [System.Drawing.Color]::FromArgb(55,  55,  55)
$cText   = [System.Drawing.Color]::FromArgb(220, 220, 220)
$cDim    = [System.Drawing.Color]::FromArgb(120, 120, 120)
$cGreen  = [System.Drawing.Color]::FromArgb(78,  201, 176)
$cYellow = [System.Drawing.Color]::FromArgb(220, 180, 80)
$cRed    = [System.Drawing.Color]::FromArgb(240, 90,  70)
$cBtnMon = [System.Drawing.Color]::FromArgb(0,   100, 160)
$cBtnWrk = [System.Drawing.Color]::FromArgb(30,  110, 60)
$cBtnGh  = [System.Drawing.Color]::FromArgb(50,  50,  50)

$fMono   = New-Object System.Drawing.Font("Consolas",  9)
$fMonoSm = New-Object System.Drawing.Font("Consolas",  8)
$fUi     = New-Object System.Drawing.Font("Segoe UI",  9)
$fUiBold = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)

# State
$script:MonitorProc            = $null
$script:WorkerProc             = $null
$script:QueueIds               = @()
$script:SelectedTranscriptFile = ""
$script:LastTranscriptLen      = 0

# Form
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "config-auto-github"
$form.Size          = New-Object System.Drawing.Size(1150, 780)
$form.MinimumSize   = New-Object System.Drawing.Size(900, 600)
$form.StartPosition = "CenterScreen"
$form.BackColor     = $cBg
$form.ForeColor     = $cText

# Split
$split                  = New-Object System.Windows.Forms.SplitContainer
$split.Dock             = "Fill"
$split.SplitterDistance = 370
$split.SplitterWidth    = 4
$split.BackColor        = $cBorder
$split.Panel1.BackColor = $cBg
$split.Panel2.BackColor = $cBg
$form.Controls.Add($split)

# Helper: label
function New-Label { param($text, $x, $y, $w = 340, $font = $fUi)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20)
    $l.Font = $font
    $l.ForeColor = $cText
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l
}

# Helper: button
function New-Btn { param($text, $x, $y, $w, $h = 36, $col = $cBtnGh)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.BackColor = $col
    $b.ForeColor = $cText
    $b.FlatStyle = "Flat"
    $b.Font = $fUi
    $b.FlatAppearance.BorderSize = 0
    $b
}

# ---- LEFT PANEL ----

$lblTitle = New-Label "config-auto-github" 12 14 300 $fUiBold
$split.Panel1.Controls.Add($lblTitle)

# Status panel
$pnlStatus           = New-Object System.Windows.Forms.Panel
$pnlStatus.Location  = New-Object System.Drawing.Point(8, 46)
$pnlStatus.Size      = New-Object System.Drawing.Size(350, 112)
$pnlStatus.BackColor = $cPanel
$pnlStatus.BorderStyle = "FixedSingle"
$split.Panel1.Controls.Add($pnlStatus)

$lblStatusHead           = New-Label "STATUS" 8 6 200 $fUi
$lblStatusHead.ForeColor = $cDim
$pnlStatus.Controls.Add($lblStatusHead)

$lblMonitor = New-Label "Monitor : --" 8 26 334 $fMono
$lblWorker  = New-Label "Worker  : --" 8 46 334 $fMono
$lblCounts  = New-Label ""             8 66 334 $fMono
$lblActive  = New-Label ""             8 88 334 $fMonoSm
$lblActive.ForeColor = $cGreen
foreach ($l in @($lblMonitor, $lblWorker, $lblCounts, $lblActive)) { $pnlStatus.Controls.Add($l) }

# Queue label
$lblQHead = New-Label "QUEUE" 12 170 60 $fUi
$lblQHead.ForeColor = $cDim
$split.Panel1.Controls.Add($lblQHead)

# Queue listbox
$lstQueue             = New-Object System.Windows.Forms.ListBox
$lstQueue.Location    = New-Object System.Drawing.Point(8, 190)
$lstQueue.Size        = New-Object System.Drawing.Size(352, 420)
$lstQueue.BackColor   = $cPanel
$lstQueue.ForeColor   = $cText
$lstQueue.BorderStyle = "FixedSingle"
$lstQueue.Font        = $fMonoSm
$lstQueue.DrawMode    = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$lstQueue.ItemHeight  = 22
$split.Panel1.Controls.Add($lstQueue)

$lstQueue.add_DrawItem({
    param($s, $e)
    $e.DrawBackground()
    if ($e.Index -lt 0) { return }
    $item = $s.Items[$e.Index]
    if     ($item -match "^\[RUN\]")  { $col = $cGreen  }
    elseif ($item -match "^\[OK \]")  { $col = $cDim    }
    elseif ($item -match "^\[ERR\]")  { $col = $cRed    }
    else                              { $col = $cYellow }
    $brush = New-Object System.Drawing.SolidBrush($col)
    $e.Graphics.DrawString($item, $e.Font, $brush, ($e.Bounds.X + 4), ($e.Bounds.Y + 3))
    $brush.Dispose()
    $e.DrawFocusRectangle()
})

$lstQueue.add_SelectedIndexChanged({
    $i = $lstQueue.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:QueueIds.Count) { return }
    $id   = $script:QueueIds[$i]
    $file = "$ScriptDir\logs\$id.log"
    $script:SelectedTranscriptFile = $file
    $script:LastTranscriptLen = 0
    if (Test-Path $file) {
        $lblTranscript.Text = "Transcript -- $id"
    } else {
        $lblTranscript.Text = "Transcript -- $id  (not started yet)"
        $rtb.Text = ""
    }
    Refresh-Transcript
})

# Buttons
$btnMon = New-Btn "Run Monitor" 8   622 170 36 $cBtnMon
$btnWrk = New-Btn "Run Worker"  190 622 170 36 $cBtnWrk
$btnGh  = New-Btn "Open Issues" 8   664 352 30
foreach ($b in @($btnMon, $btnWrk, $btnGh)) { $split.Panel1.Controls.Add($b) }

$btnMon.add_Click({
    $btnMon.Enabled = $false
    $btnMon.Text = "Running..."
    $script:MonitorProc = Start-Process "powershell.exe" `
        -ArgumentList "-NonInteractive -File `"$ScriptDir\monitor.ps1`"" `
        -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden
})

$btnWrk.add_Click({
    $btnWrk.Enabled = $false
    $btnWrk.Text = "Running..."
    $script:SelectedTranscriptFile = $LogFile
    $script:LastTranscriptLen = 0
    $lblTranscript.Text = "Log -- main.log"
    $script:WorkerProc = Start-Process "powershell.exe" `
        -ArgumentList "-NonInteractive -File `"$ScriptDir\worker.ps1`"" `
        -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden
})

$btnGh.add_Click({ Start-Process "https://github.com/tummyslyunopened/config/issues" })

# ---- RIGHT PANEL ----

$lblTranscript          = New-Object System.Windows.Forms.Label
$lblTranscript.Text     = "Log -- main.log"
$lblTranscript.Font     = $fUi
$lblTranscript.ForeColor = $cDim
$lblTranscript.Location = New-Object System.Drawing.Point(10, 10)
$lblTranscript.Size     = New-Object System.Drawing.Size(600, 20)
$split.Panel2.Controls.Add($lblTranscript)

$btnShowLog = New-Btn "main.log" 0 4 80 22
$btnShowLog.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$btnShowLog.FlatAppearance.BorderSize = 0
$split.Panel2.Controls.Add($btnShowLog)

$btnShowLog.add_Click({
    $script:SelectedTranscriptFile = $LogFile
    $script:LastTranscriptLen = 0
    $lblTranscript.Text = "Log -- main.log"
    Refresh-Transcript
})

$rtb             = New-Object System.Windows.Forms.RichTextBox
$rtb.BackColor   = [System.Drawing.Color]::FromArgb(16, 16, 16)
$rtb.ForeColor   = $cText
$rtb.Font        = $fMonoSm
$rtb.ReadOnly    = $true
$rtb.BorderStyle = "None"
$rtb.ScrollBars  = "Vertical"
$rtb.WordWrap    = $false
$rtb.Location    = New-Object System.Drawing.Point(0, 34)
$split.Panel2.Controls.Add($rtb)

$split.Panel2.add_Resize({
    $rtb.Size = New-Object System.Drawing.Size($split.Panel2.Width, ($split.Panel2.Height - 34))
    $btnShowLog.Location = New-Object System.Drawing.Point(($split.Panel2.Width - 88), 4)
})

# ---- Refresh logic ----

function Refresh-Transcript {
    $file = $script:SelectedTranscriptFile
    if (-not $file) { $file = $LogFile }
    if (-not (Test-Path $file -ErrorAction SilentlyContinue)) { return }
    try { $content = [System.IO.File]::ReadAllText($file) } catch { return }
    if ($content.Length -eq $script:LastTranscriptLen) { return }
    $script:LastTranscriptLen = $content.Length
    $atBottom = ($rtb.SelectionStart -ge ($rtb.TextLength - 20)) -or ($rtb.TextLength -lt 200)
    $rtb.Text = $content
    if ($atBottom) { $rtb.SelectionStart = $rtb.TextLength; $rtb.ScrollToCaret() }
}

function Refresh-Status {
    # Queue
    $Queue = @()
    if (Test-Path $QueueFile) {
        try { $Queue = @(Get-Content $QueueFile -Raw | ConvertFrom-Json) } catch {}
    }

    # Task scheduler state
    $monTask = Get-ScheduledTask -TaskName "config-auto-github-monitor" -ErrorAction SilentlyContinue
    $wrkTask = Get-ScheduledTask -TaskName "config-auto-github-worker"  -ErrorAction SilentlyContinue
    $mState  = if ($monTask) { "$($monTask.State)" } else { "not installed" }
    $wState  = if ($wrkTask) { "$($wrkTask.State)"  } else { "not installed" }
    if ($script:MonitorProc -and -not $script:MonitorProc.HasExited) { $mState = "running (manual)" }
    if ($script:WorkerProc  -and -not $script:WorkerProc.HasExited)  { $wState  = "running (manual)" }

    $lblMonitor.Text = "Monitor : $mState"
    $lblWorker.Text  = "Worker  : $wState"

    $nPending = @($Queue | Where-Object { $_.status -eq "pending"     }).Count
    $nRun     = @($Queue | Where-Object { $_.status -eq "in_progress" }).Count
    $nDone    = @($Queue | Where-Object { $_.status -eq "done"        }).Count
    $nErr     = @($Queue | Where-Object { $_.status -in @("error","timeout") }).Count
    $lblCounts.Text = "pending $nPending  |  running $nRun  |  done $nDone  |  err $nErr"

    $active = $Queue | Where-Object { $_.status -eq "in_progress" } | Select-Object -First 1
    if ($active) {
        $s = if ($active.startedAt) { [int]((Get-Date) - [datetime]$active.startedAt).TotalSeconds } else { 0 }
        $lblActive.Text = ">> $($active.id)  [${s}s]"
        if ((-not $script:SelectedTranscriptFile) -or ($script:SelectedTranscriptFile -eq $LogFile)) {
            if ($active.transcript) {
                $script:SelectedTranscriptFile = $active.transcript
                $script:LastTranscriptLen = 0
                $lblTranscript.Text = "Transcript -- $($active.id)"
            }
        }
    } else {
        $lblActive.Text = ""
    }

    # Re-enable buttons when processes finish
    if ($script:MonitorProc -and $script:MonitorProc.HasExited) {
        $btnMon.Text = "Run Monitor"; $btnMon.Enabled = $true; $script:MonitorProc = $null
    }
    if ($script:WorkerProc -and $script:WorkerProc.HasExited) {
        $btnWrk.Text = "Run Worker"; $btnWrk.Enabled = $true; $script:WorkerProc = $null
    }

    # Rebuild queue list
    $prevSel = $lstQueue.SelectedIndex
    $lstQueue.BeginUpdate()
    $lstQueue.Items.Clear()
    $script:QueueIds = @()
    foreach ($item in ($Queue | Sort-Object addedAt -Descending)) {
        $icon = switch ($item.status) {
            "in_progress" { "[RUN]" }
            "done"        { "[OK ]" }
            "pending"     { "[ > ]" }
            default       { "[ERR]" }
        }
        $repo = $item.repo.Split("/")[1]
        $lstQueue.Items.Add("$icon $($item.type.PadRight(16)) $repo #$($item.number)") | Out-Null
        $script:QueueIds += $item.id
    }
    $lstQueue.EndUpdate()
    if ($prevSel -ge 0 -and $prevSel -lt $lstQueue.Items.Count) { $lstQueue.SelectedIndex = $prevSel }

    Refresh-Transcript
}

# Timer
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({ Refresh-Status })
$timer.Start()

$form.add_Shown({ Refresh-Status })
$form.add_FormClosed({ $timer.Stop() })

[System.Windows.Forms.Application]::Run($form)
