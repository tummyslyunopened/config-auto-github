# Handle the "/help" command -- send the designer a syntax reminder and the
# list of currently-watched repos.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
. "$ScriptDir\lib-telegram.ps1"

try { $cfg = Get-TgConfig $ScriptDir } catch { Write-Error $_.Exception.Message; exit 2 }

# Same parsing as telegram-cmd-issue (kept inline to avoid sharing state).
function Get-WatchedShortNames {
    $gm = Join-Path $RepoRoot ".gitmodules"
    $shortNames = @("config")
    if (-not (Test-Path $gm)) { return $shortNames }
    $currentPath = $null
    foreach ($line in (Get-Content $gm)) {
        $t = $line.Trim()
        if     ($t -match '^path\s*=\s*(.+)$') { $currentPath = $matches[1].Trim() }
        elseif ($t -match '^url\s*=\s*(.+)$' -and $currentPath) {
            $url  = ($matches[1].Trim()) -replace '\.git$', ''
            $slug = $null
            if     ($url -match '^github:(.+)$')              { $slug = $matches[1] }
            elseif ($url -match '^https://github\.com/(.+)$') { $slug = $matches[1] }
            elseif ($url -match '^git@github\.com:(.+)$')     { $slug = $matches[1] }
            if ($slug -and $slug -like 'tummyslyunopened/*' -and $slug -ne 'tummyslyunopened/config-auto-github') {
                $shortNames += ($slug -replace '^tummyslyunopened/','')
            }
            $currentPath = $null
        }
    }
    return ($shortNames | Sort-Object)
}

$repos = (Get-WatchedShortNames) -join ', '
$msg = @"
Commands:

  /issue <repo>: <title>
    body lines, optional
  Create a GitHub issue in the named repo.
  The bot will reply with the issue URL.

  /help
  This message.

Watched repos:
  $repos
"@

$null = & "$ScriptDir\telegram-send.ps1" -Body $msg -Kind "command-reply" 2>$null
exit 0