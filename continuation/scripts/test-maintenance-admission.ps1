# Execution tests for the shared maintenance admission gate (deploy + rollback use it).
# A local fake helper serves /api/health, /api/jobs/latest and /api/maintenance only.
# No real helper is stopped and no product/theme state is touched.
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gallery-maintenance-common.ps1')
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$nodeExe = 'C:\Users\Toby\AppData\Local\CodexDreamSkin\engine\runtime\node\node.exe'
$fakeJs = Join-Path $PSScriptRoot 'fake-helper-server.js'
$deploy = Join-Path $PSScriptRoot 'deploy-gallery.ps1'
$RealTarget = 'D:\CodexSkin'
$failures = 0
function Assert($c, $m) { if (-not $c) { throw ('ASSERT: ' + $m) } }
function Check([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output ('PASS ' + $Name) }
  catch { $script:failures++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Get-FreePort {
  for ($i = 0; $i -lt 60; $i++) {
    $p = Get-Random -Minimum 9450 -Maximum 9899
    if (-not (Get-ListenerPid $p)) { return $p }
  }
  throw 'no free port'
}
function Start-Fake([string]$scriptPath, [string]$mode) {
  $port = Get-FreePort
  $proc = Start-Process -FilePath $nodeExe -ArgumentList @($scriptPath, [string]$port, $mode) -PassThru -WindowStyle Hidden
  for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 100
    if (Get-ListenerPid $port) { break }
  }
  Assert (Get-ListenerPid $port) ('fake helper did not listen on ' + $port)
  return [ordered]@{ proc = $proc; port = $port }
}
function Stop-Fake($fake) {
  try { Stop-Process -Id $fake.proc.Id -Force -ErrorAction SilentlyContinue } catch { }
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 100; if (-not (Get-ListenerPid $fake.port)) { break } }
}
function Expect-Throw([scriptblock]$Body, [string]$Pattern) {
  $threw = $false
  try { & $Body } catch { $threw = $true; if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw ('threw with unexpected message: ' + $_.Exception.Message) } }
  if (-not $threw) { throw 'expected a throw but none happened' }
}
function Invoke-PSFile([string]$File, [string[]]$ArgList) {
  $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
  try {
    $proc = Start-Process -FilePath $ps -ArgumentList $ArgList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    return $proc.ExitCode
  } finally { Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('admission-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $work

Check 'admission engages the latch when the helper is idle' {
  $fake = Start-Fake $fakeJs 'idle'
  try {
    $info = Assert-MaintenanceAdmission $fake.port 'deploy'
    Assert ([string]$info.latch -eq 'set') ('expected latch set, got ' + [string]$info.latch)
  } finally { Stop-Fake $fake }
}

Check 'admission refuses a running job' {
  $fake = Start-Fake $fakeJs 'running'
  try { Expect-Throw { Assert-MaintenanceAdmission $fake.port 'rollback' } 'running' } finally { Stop-Fake $fake }
}

Check 'admission refuses an unconfirmed termination lock' {
  $fake = Start-Fake $fakeJs 'unconfirmed'
  try { Expect-Throw { Assert-MaintenanceAdmission $fake.port 'deploy' } 'unconfirmed' } finally { Stop-Fake $fake }
}

Check 'admission refuses when a v2 job-state query fails' {
  $fake = Start-Fake $fakeJs 'jobsfail'
  try { Expect-Throw { Assert-MaintenanceAdmission $fake.port 'deploy' } 'cannot verify' } finally { Stop-Fake $fake }
}

Check 'admission treats an old service without a job API as supported-conservatively' {
  $fake = Start-Fake $fakeJs 'old'
  try {
    $info = Assert-MaintenanceAdmission $fake.port 'deploy'
    Assert ([string]$info.latch -eq 'unsupported') ('old service should report latch unsupported, got ' + [string]$info.latch)
  } finally { Stop-Fake $fake }
}

Check 'deploy refuses end-to-end on an unconfirmed lock and does not touch files' {
  $targetRoot = Join-Path $work 'CodexSkin'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $targetRoot 'app'), (Join-Path $targetRoot 'helper')
  Copy-Item -LiteralPath (Join-Path $RealTarget 'launcher.ps1') -Destination (Join-Path $targetRoot 'launcher.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $RealTarget 'app/index.html') -Destination (Join-Path $targetRoot 'app/index.html') -Force
  Copy-Item -LiteralPath $fakeJs -Destination (Join-Path $targetRoot 'helper/gallery-helper.js') -Force
  $beforeLauncher = Get-Sha256 (Join-Path $targetRoot 'launcher.ps1')
  $shortcut = Join-Path $work 'gallery.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($shortcut)
  $link.TargetPath = $ps
  $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $targetRoot 'launcher.ps1') + '"'
  $link.WorkingDirectory = $targetRoot
  $link.Save()
  $fake = Start-Fake (Join-Path $targetRoot 'helper/gallery-helper.js') 'unconfirmed'
  try {
    $code = Invoke-PSFile $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deploy, '-SourceRoot', 'D:\Dirty_work\codex-skin-audit\source', '-TargetRoot', $targetRoot, '-BackupRoot', (Join-Path $work 'backup'), '-ShortcutPath', $shortcut, '-HelperPort', [string]$fake.port, '-Apply')
    Assert ($code -ne 0) 'deploy must fail on an unconfirmed lock'
    Assert ((Get-Sha256 (Join-Path $targetRoot 'launcher.ps1')) -eq $beforeLauncher) 'launcher must be untouched after refusal'
    Assert (Get-ListenerPid $fake.port) 'fake helper must still be running (stop must not be reached)'
  } finally { Stop-Fake $fake }
}

try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($failures -gt 0) { Write-Output ('FAILURES=' + $failures); exit 1 }
Write-Output 'ALL MAINTENANCE ADMISSION CHECKS PASS'
exit 0
