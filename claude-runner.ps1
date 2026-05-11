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

# Outgoing-comment ID tracking. claude posts comments via gh, gh prints the
# resulting URL on stdout, which lands here in tool_result text. We extract
# the comment IDs and append to .data/outgoing-comments.jsonl so monitor.ps1
# can filter them out on the way back in (preventing the bot from looping
# on its own confirmation comments).
$OutgoingFile = "$PSScriptRoot\.data\outgoing-comments.jsonl"
$null = New-Item -ItemType Directory -Force -Path (Split-Path $OutgoingFile -Parent)
function Record-OutgoingCommentIds {
    param($content)
    $text = if ($content -is [array]) { ($content | ForEach-Object { $_.text }) -join "`n" } else { [string]$content }
    if ([string]::IsNullOrEmpty($text)) { return }
    # Issue + PR conversation comments (same ID space, /issues/comments API)
    $matchesIssueComment = [regex]::Matches($text, 'https://github\.com/[^/\s]+/[^/\s]+/(?:issues|pull)/\d+#issuecomment-(\d+)')
    foreach ($m in $matchesIssueComment) {
        $entry = @{
            recorded_at = (Get-Date -Format "o")
            kind        = "issue_comment"
            id          = [long]$m.Groups[1].Value
            url         = $m.Value
        } | ConvertTo-Json -Compress
        Add-Content -Path $OutgoingFile -Value $entry -Encoding utf8
    }
    # PR review comments (separate ID space, /pulls/comments API)
    $matchesPrReview = [regex]::Matches($text, 'https://github\.com/[^/\s]+/[^/\s]+/pull/\d+#discussion_r(\d+)')
    foreach ($m in $matchesPrReview) {
        $entry = @{
            recorded_at = (Get-Date -Format "o")
            kind        = "pr_review_comment"
            id          = [long]$m.Groups[1].Value
            url         = $m.Value
        } | ConvertTo-Json -Compress
        Add-Content -Path $OutgoingFile -Value $entry -Encoding utf8
    }
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
                        # Only record IDs from successful tool calls -- an
                        # is_error tool_result means the comment was never
                        # actually posted (e.g. gh auth failure), so any URL
                        # in the content would be from a help text or stale
                        # stdout, not a real outgoing comment.
                        if (-not $b.is_error) {
                            Record-OutgoingCommentIds $b.content
                        }
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