$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$Prompt = Get-Content "$ScriptDir\prompt.md" -Raw

Set-Location $RepoRoot
claude --print --dangerously-skip-permissions $Prompt
