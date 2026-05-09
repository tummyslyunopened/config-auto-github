# Runs claude in stream-json mode and pretty-prints events to a transcript file in real time.
param(
    [Parameter(Mandatory)] [string] $ClaudeExe,
    [Parameter(Mandatory)] [string] $PromptFile,
    [Parameter(Mandatory)] [string] $TranscriptFile,
    [Parameter(Mandatory)] [string] $RepoRoot
)

Set-Location $RepoRoot
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_EDITOR          = "true"
$env:GH_PROMPT_DISABLED  = "1"

$prompt = [System.IO.File]::ReadAllText($PromptFile)

# Open transcript with shared read so the GUI can tail it
$fs = [System.IO.File]::Open(
    $TranscriptFile,
    [System.IO.FileMode]::Append,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::Read
)
$writer = New-Object System.IO.StreamWriter -ArgumentList $fs, ([System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true

function W { param([string]$Line) $writer.WriteLine($Line) }
function Now { (Get-Date).ToString("HH:mm:ss") }

function Format-Args {
    param($obj)
    try { $s = $obj | ConvertTo-Json -Compress -Depth 3 } catch { $s = "$obj" }
    if ($s.Length -gt 280) { $s = $s.Substring(0, 280) + " ..." }
    $s
}

function Write-Result {
    param($content)
    $text = if ($content -is [array]) { ($content | ForEach-Object { $_.text }) -join "`n" } else { [string]$content }
    $lines = $text -split "`r?`n"
    $shown = $lines | Select-Object -First 8
    foreach ($l in $shown) { W "      $l" }
    if ($lines.Count -gt 8) { W "      ... ($($lines.Count - 8) more lines)" }
}

try {
    & $ClaudeExe --print --verbose --output-format stream-json --dangerously-skip-permissions $prompt 2>&1 | ForEach-Object {
        $raw = "$_"
        $evt = $null
        try { $evt = $raw | ConvertFrom-Json -ErrorAction Stop } catch { W $raw; return }

        switch ($evt.type) {
            "system" {
                if ($evt.subtype -eq "init") {
                    W ""
                    W "[$(Now)] session init  model=$($evt.model)"
                }
            }
            "assistant" {
                foreach ($b in $evt.message.content) {
                    if ($b.type -eq "text" -and $b.text) {
                        W ""
                        W "[$(Now)] >>> Claude:"
                        foreach ($l in ($b.text -split "`r?`n")) { W "   $l" }
                    } elseif ($b.type -eq "tool_use") {
                        W ""
                        W "[$(Now)] [tool: $($b.name)]  $(Format-Args $b.input)"
                    } elseif ($b.type -eq "thinking" -and $b.thinking) {
                        W "[$(Now)] (thinking) $($b.thinking.Substring(0, [Math]::Min(200, $b.thinking.Length)))"
                    }
                }
            }
            "user" {
                foreach ($b in $evt.message.content) {
                    if ($b.type -eq "tool_result") {
                        $isErr = if ($b.is_error) { " (ERROR)" } else { "" }
                        W "[$(Now)]   -> result$isErr"
                        Write-Result $b.content
                    }
                }
            }
            "result" {
                W ""
                $cost = if ($evt.total_cost_usd) { "`$" + [math]::Round($evt.total_cost_usd, 4) } else { "n/a" }
                $secs = if ($evt.duration_ms) { [int]($evt.duration_ms / 1000) } else { 0 }
                $exitNote = if ($evt.is_error) { " (claude reported is_error=true)" } else { "" }
                W "[$(Now)] === DONE === cost=$cost duration=${secs}s turns=$($evt.num_turns)$exitNote"
            }
        }
    }
} finally {
    $writer.Flush()
    $writer.Close()
    $fs.Close()
}

exit $LASTEXITCODE