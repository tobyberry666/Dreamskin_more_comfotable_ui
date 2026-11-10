# B-01 regression: rollback must only restore a 'writing' existing file when its
# current content is provably the original OR the deployed bytes; unknown content must
# be rejected before any stop/write and left untouched.
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gallery-maintenance-common.ps1')
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$rollback = Join-Path $PSScriptRoot 'rollback-gallery.ps1'
$sourceLauncher = 'D:\Dirty_work\codex-skin-audit\source\launcher.ps1'
$realLauncher = 'D:\CodexSkin\launcher.ps1'
$failures = 0
function Assert($c, $m) { if (-not $c) { throw ('ASSERT: ' + $m) } }
function Check([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output ('PASS ' + $Name) }
  catch { $script:failures++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Invoke-PSFile([string]$File, [string[]]$ArgList) {
  $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
  try {
    $proc = Start-Process -FilePath $ps -ArgumentList $ArgList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    return $proc.ExitCode
  } finally { Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue }
}
function New-IsoState([string]$Work) {
  $iso = Join-Path $Work 'appdata'
  $state = Join-Path $iso 'CodexDreamSkin'
  $dir = Join-Path $state 'themes/theme-a'
  $null = New-Item -ItemType Directory -Force -Path $dir
  [IO.File]::WriteAllText((Join-Path $dir 'theme.json'), '{"id":"theme-a"}', (New-Object Text.UTF8Encoding($false)))
  $active = Join-Path $state 'active-theme'
  $null = New-Item -ItemType Directory -Force -Path $active
  [IO.File]::WriteAllText((Join-Path $active 'theme.json'), '{"id":"theme-a"}', (New-Object Text.UTF8Encoding($false)))
  return [ordered]@{ localAppData = $iso; stateRoot = $state }
}
function New-WritingCase([string]$Work, [string]$Name, [string]$CurrentLauncher, [string]$OriginalLauncher, [string]$DeployedLauncher) {
  $root = Join-Path $Work ($Name + '/CodexSkin')
  $null = New-Item -ItemType Directory -Force -Path $root
  [IO.File]::WriteAllText((Join-Path $root 'launcher.ps1'), $CurrentLauncher, (New-Object Text.UTF8Encoding($false)))
  $backupDir = Join-Path $Work ($Name + '-backup')
  $filesDir = Join-Path $backupDir 'files'
  $null = New-Item -ItemType Directory -Force -Path $filesDir
  [IO.File]::WriteAllText((Join-Path $filesDir 'launcher.ps1'), $OriginalLauncher, (New-Object Text.UTF8Encoding($false)))
  $originalSha = Get-Sha256 (Join-Path $filesDir 'launcher.ps1')
  $deployedSha = Get-Sha256 (Join-Path (Join-Path $Work ($Name + '-deployed')) 'launcher.ps1')
  $files = @()
  $files += [ordered]@{ path = 'launcher.ps1'; targetExists = $true; status = 'writing'; sourceSha256 = $deployedSha; targetSha256 = $originalSha }
  foreach ($rel in @('app/index.html', 'app/app.js', 'app/styles.css', 'helper/gallery-helper.js', 'helper/engine-worker.ps1')) {
    $files += [ordered]@{ path = $rel; targetExists = $false; status = 'pending'; sourceSha256 = ('0' * 64); targetSha256 = $null }
  }
  $manifest = [ordered]@{ mode = 'apply'; state = 'partial'; targetRoot = $root; backupDir = $backupDir; files = $files; themesBefore = @() }
  Write-JsonAtomic (Join-Path $backupDir 'manifest.json') $manifest
  return [ordered]@{ root = $root; backupDir = $backupDir }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('writing-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $work
$iso = New-IsoState $work; $env:LOCALAPPDATA = $iso.localAppData
$original = [IO.File]::ReadAllText($realLauncher, [Text.Encoding]::UTF8)
$deployed = [IO.File]::ReadAllText($sourceLauncher, [Text.Encoding]::UTF8)
$unknown = $original + "`n# USER MODIFICATION AFTER INTERRUPTED DEPLOY"

# Materialize deployed bytes so the manifest can record the deployed hash.
foreach ($name in @('k-orig', 'k-deploy', 'k-unknown')) {
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $work ($name + '-deployed'))
  [IO.File]::WriteAllText((Join-Path (Join-Path $work ($name + '-deployed')) 'launcher.ps1'), $deployed, (New-Object Text.UTF8Encoding($false)))
}

Check 'writing + current == original bytes is allowed and restored' {
  $case = New-WritingCase $work 'k-orig' $original $original $deployed
  $code = Invoke-PSFile $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rollback, '-BackupDir', $case.backupDir, '-TargetRoot', $case.root, '-HelperPort', '0', '-Apply')
  Assert ($code -eq 0) ('expected success, got ' + $code)
  Assert ((Get-Sha256 (Join-Path $case.root 'launcher.ps1')) -eq (Get-Sha256 (Join-Path $case.backupDir 'files/launcher.ps1'))) 'launcher should equal original after restore'
}

Check 'writing + current == deployed bytes is allowed and restored to original' {
  $case = New-WritingCase $work 'k-deploy' $deployed $original $deployed
  $code = Invoke-PSFile $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rollback, '-BackupDir', $case.backupDir, '-TargetRoot', $case.root, '-HelperPort', '0', '-Apply')
  Assert ($code -eq 0) ('expected success, got ' + $code)
  Assert ((Get-Sha256 (Join-Path $case.root 'launcher.ps1')) -eq (Get-Sha256 (Join-Path $case.backupDir 'files/launcher.ps1'))) 'launcher should be restored to original'
}

Check 'writing + unknown user modification is rejected and not overwritten' {
  $case = New-WritingCase $work 'k-unknown' $unknown $original $deployed
  $before = Get-Sha256 (Join-Path $case.root 'launcher.ps1')
  $code = Invoke-PSFile $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rollback, '-BackupDir', $case.backupDir, '-TargetRoot', $case.root, '-HelperPort', '0', '-Apply')
  Assert ($code -ne 0) 'expected rejection of unknown content'
  Assert ((Get-Sha256 (Join-Path $case.root 'launcher.ps1')) -eq $before) 'unknown content must be left untouched'
}

try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($failures -gt 0) { Write-Output ('FAILURES=' + $failures); exit 1 }
Write-Output 'ALL WRITING-BOUNDARY CHECKS PASS'
exit 0
