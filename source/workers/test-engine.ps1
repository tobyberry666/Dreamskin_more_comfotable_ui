param([string]$EngineRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin/engine'))
$ErrorActionPreference = 'Stop'
$worker = Join-Path (Split-Path -Parent $PSScriptRoot) 'helper/engine-worker.ps1'
function Assert($condition, $message) { if (-not $condition) { throw "ASSERT: $message" } }
Assert (Test-Path -LiteralPath $worker) 'Task3 engine worker feature is missing'
$root = Join-Path $PSScriptRoot ('engine-test-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Path $root | Out-Null
$archive = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'workers/rainwashed-celadon.zip'
$hash = '14dadf429cfefdc50d48ac0b3e2f8febb5cb379a359e9300d1f20ee3cc864c40'
$script:sequence = 0
function Invoke-Worker($request) {
  $script:sequence++
  $requestPath = Join-Path $root "$script:sequence.request.json"
  $resultPath = Join-Path $root "$script:sequence.result.json"
  [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  & "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $worker -RequestPath $requestPath -ResultPath $resultPath -StateRoot $state -EngineRoot $EngineRoot
  Assert (Test-Path -LiteralPath $resultPath) 'worker must always publish result JSON'
  $bytes = [IO.File]::ReadAllBytes($resultPath)
  Assert (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187)) 'result must be BOM-free UTF8'
  return ([IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Import-Request($adapt = $false) { return @{action='import';archivePath=$archive;expectedBytes=631581;expectedSha256=$hash;adaptWindows=$adapt} }
function Snapshot { return ((Get-ChildItem -LiteralPath $state -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|') }
$r = Invoke-Worker (Import-Request)
Assert (-not $r.ok -and $r.message -match 'does not support windows') "original macOS archive must fail Windows validation: $($r.message)"
Write-Output 'PASS original macOS archive rejected'
$r = Invoke-Worker (Import-Request $true)
Assert $r.ok "adapted import must pass real Windows engine: $($r.message)"
$id = $r.theme.id
Assert ($id -eq 'guiming.ink.rainwashed-celadon-windows-local') 'local identity contract'
Assert ($r.theme.name -match 'Windows') 'local adaptation label'
$themeDir = Join-Path $state "themes/$id"
Assert (Test-Path -LiteralPath (Join-Path $themeDir 'theme.json')) 'actual runtime theme exists'
Assert (@(Get-ChildItem -LiteralPath $themeDir -File).Count -eq 3) 'saved directory holds runtime files only'
Write-Output "PASS adapted import: $id"
$count = @(Get-ChildItem -LiteralPath (Join-Path $state 'themes') -Directory).Count
$r = Invoke-Worker (Import-Request $true)
Assert ($r.ok -and $r.theme.id -eq $id) 'duplicate returns same ID'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $state 'themes') -Directory).Count -eq $count) 'duplicate count remains stable'
Write-Output 'PASS duplicate import stable count and ID'
$before = Snapshot
$bad = Import-Request $true
$bad.expectedSha256 = '0' * 64
$r = Invoke-Worker $bad
Assert (-not $r.ok -and $r.message -match 'hash|SHA') 'bad hash rejected'
Assert ((Snapshot) -ceq $before) 'bad hash leaves state unchanged'
Write-Output 'PASS bad hash rejected without mutation'
foreach ($badId in @('../outside', '..\outside', 'C:\outside', 'safe/../../outside')) {
  $r = Invoke-Worker @{action='apply';themeId=$badId}
  Assert (-not $r.ok -and $r.message -match 'ID') 'traversal rejected before apply'
  Assert ((Snapshot) -ceq $before) 'traversal leaves state unchanged'
}
Write-Output 'PASS path traversal rejected without mutation'
$r = Invoke-Worker @{action='apply';themeId=$id}
Assert (-not $r.ok -and $r.message -match 'isolated') 'isolated apply must never start real Codex'
Assert ((Snapshot) -ceq $before) 'isolated apply leaves state unchanged'
Write-Output 'PASS isolated apply blocked before starting Codex'
Write-Output "Evidence: $root"