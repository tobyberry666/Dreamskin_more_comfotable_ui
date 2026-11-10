$ErrorActionPreference = 'Stop'
$worker = Join-Path (Split-Path -Parent $PSScriptRoot) 'helper/engine-worker.ps1'
$root = Join-Path $PSScriptRoot ('engine-security-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Path $root | Out-Null
$archive = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'workers/rainwashed-celadon.zip'
$hash = '14dadf429cfefdc50d48ac0b3e2f8febb5cb379a359e9300d1f20ee3cc864c40'
$cases = @(
  @{name='bad hash';request=@{action='import';archivePath=$archive;expectedBytes=631581;expectedSha256=('0' * 64);adaptWindows=$true};match='SHA256'},
  @{name='bad size';request=@{action='import';archivePath=$archive;expectedBytes=631580;expectedSha256=$hash;adaptWindows=$true};match='size'},
  @{name='traversal slash';request=@{action='apply';themeId='../outside'};match='ID'},
  @{name='traversal backslash';request=@{action='apply';themeId=('..' + [char]92 + 'outside')};match='ID'},
  @{name='absolute ID';request=@{action='apply';themeId='C:/outside'};match='ID'},
  @{name='reserved ID';request=@{action='apply';themeId='CON'};match='ID'},
  @{name='isolated apply';request=@{action='apply';themeId='guiming.ink.rainwashed-celadon-windows-local'};match='isolated'},
  @{name='unsupported action';request=@{action='remove'};match='Unsupported'}
)
$i = 0
foreach ($case in $cases) {
  $i++
  $requestPath = Join-Path $root "$i.request.json"
  $resultPath = Join-Path $root "$i.result.json"
  [IO.File]::WriteAllText($requestPath, ($case.request | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  & "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $worker -RequestPath $requestPath -ResultPath $resultPath -StateRoot $state
  if (-not (Test-Path -LiteralPath $resultPath)) { throw 'Missing structured result' }
  $result = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($result.ok -or $result.message -notmatch $case.match) { throw "Unexpected result for $($case.name): $($result.message)" }
  if (Test-Path -LiteralPath $state) { throw "State mutated for $($case.name)" }
  Write-Output "PASS $($case.name): rejected without state mutation"
}
Write-Output "Evidence: $root"
