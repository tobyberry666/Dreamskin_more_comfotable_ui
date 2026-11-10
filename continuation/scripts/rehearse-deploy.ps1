# Rehearse deploy/rollback on throwaway copies (never touches D:\CodexSkin or real state).
# Covers: normal deploy+rollback, mid-deploy failure, launch failure, target-dir occupancy,
# out-of-whitelist rollback, duplicate paths, new-file drift, existing-file drift,
# and post-deploy theme preservation with a non-empty snapshot assertion.
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
[CmdletBinding()]
param(
  [string]$SourceRoot = 'D:\Dirty_work\codex-skin-audit\source',
  [string]$RealTarget = 'D:\CodexSkin',
  [string]$WorkRoot = 'D:\Dirty_work\codex-skin-audit\continuation\rehearsal'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gallery-maintenance-common.ps1')
$deploy = Join-Path $PSScriptRoot 'deploy-gallery.ps1'
$rollback = Join-Path $PSScriptRoot 'rollback-gallery.ps1'
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$failures = 0

function Assert($condition, $message) { if (-not $condition) { throw ('ASSERT: ' + $message) } }
function Check([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output ('PASS ' + $Name) }
  catch { $script:failures++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function New-IsoState([string]$Work) {
  # LOCALAPPDATA must be the PARENT of CodexDreamSkin; the maintenance scripts append it once.
  $iso = Join-Path $Work 'appdata'
  $state = Join-Path $iso 'CodexDreamSkin'
  foreach ($id in @('theme-a', 'theme-b')) {
    $dir = Join-Path $state ('themes/' + $id)
    $null = New-Item -ItemType Directory -Force -Path $dir
    [IO.File]::WriteAllText((Join-Path $dir 'theme.json'), ('{"id":"' + $id + '","name":"' + $id + '"}'), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $dir 'art.png'), 'PNGDATA-' + $id, (New-Object Text.UTF8Encoding($false)))
  }
  $active = Join-Path $state 'active-theme'
  $null = New-Item -ItemType Directory -Force -Path $active
  [IO.File]::WriteAllText((Join-Path $active 'theme.json'), '{"id":"theme-a","name":"theme-a"}', (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $active 'theme.css'), 'body{}', (New-Object Text.UTF8Encoding($false)))
  return [ordered]@{ localAppData = $iso; stateRoot = $state }
}
function New-Target([string]$Root, [string]$Work) {
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $Root 'app'), (Join-Path $Root 'helper')
  $originals = @{}
  foreach ($relative in @('launcher.ps1', 'app/index.html', 'helper/gallery-helper.js')) {
    $from = Join-Path $RealTarget ($relative.Replace('/', '\'))
    $to = Join-Path $Root ($relative.Replace('/', '\'))
    Copy-Item -LiteralPath $from -Destination $to -Force
    $originals[$relative] = Get-Sha256 $to
  }
  $shortcut = Join-Path $Work ('gallery-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.lnk')
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($shortcut)
  $link.TargetPath = $ps
  $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'launcher.ps1') + '"'
  $link.WorkingDirectory = $Root
  $link.Save()
  return [ordered]@{ root = $Root; shortcut = $shortcut; originals = $originals }
}
function Invoke-PSFile([string]$File, [string[]]$ArgList) {
  $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
  try {
    $proc = Start-Process -FilePath $ps -ArgumentList $ArgList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    return $proc.ExitCode
  } finally { Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue }
}
function Invoke-Deploy($target, $backupRoot, $extraArgs) {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deploy, '-SourceRoot', $SourceRoot, '-TargetRoot', $target.root, '-BackupRoot', $backupRoot, '-ShortcutPath', $target.shortcut, '-HelperPort', '9399', '-Apply')
  if ($extraArgs) { $argList += $extraArgs }
  return (Invoke-PSFile $ps $argList)
}
function Invoke-Rollback($target, $backupDir) {
  return (Invoke-PSFile $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rollback, '-BackupDir', $backupDir, '-TargetRoot', $target.root, '-HelperPort', '9399', '-Apply'))
}
function Get-LatestBackup([string]$BackupRoot) {
  $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object LastWriteTime)
  if ($dirs.Count -eq 0) { throw 'no backup dir created' }
  return $dirs[-1].FullName
}
function Assert-Originals($target) {
  foreach ($relative in $target.originals.Keys) {
    $file = Join-Path $target.root ($relative.Replace('/', '\'))
    Assert (Test-Path -LiteralPath $file -PathType Leaf) ('original missing after rollback: ' + $relative)
    Assert ((Get-Sha256 $file) -eq $target.originals[$relative]) ('original hash mismatch after rollback: ' + $relative)
  }
  foreach ($relative in @('app/app.js', 'app/styles.css', 'helper/engine-worker.ps1')) {
    $file = Join-Path $target.root ($relative.Replace('/', '\'))
    Assert (-not (Test-Path -LiteralPath $file -PathType Leaf)) ('new file still present after rollback: ' + $relative)
  }
}
function Assert-Deployed($target) {
  foreach ($relative in @(Get-AllowedFiles)) {
    $source = Join-Path $SourceRoot ($relative.Replace('/', '\'))
    $targetFile = Join-Path $target.root ($relative.Replace('/', '\'))
    Assert (Test-Path -LiteralPath $targetFile -PathType Leaf) ('deployed file missing: ' + $relative)
    Assert ((Get-Sha256 $targetFile) -eq (Get-Sha256 $source)) ('deployed hash mismatch: ' + $relative)
  }
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
$work = Join-Path $WorkRoot ('work-' + $stamp)
$null = New-Item -ItemType Directory -Force -Path $work
$backupRoot = Join-Path $work 'backup'
$null = New-Item -ItemType Directory -Force -Path $backupRoot
Write-Output ('Rehearsal work: ' + $work)

Check 'A normal deploy then rollback restores originals and removes new files' {
  $iso = New-IsoState (Join-Path $work 'A'); $env:LOCALAPPDATA = $iso.localAppData
  $target = New-Target (Join-Path $work 'A/CodexSkin') (Join-Path $work 'A')
  Assert ((Invoke-Deploy $target $backupRoot $null) -eq 0) 'deploy should succeed'
  Assert-Deployed $target
  $backupDir = Get-LatestBackup $backupRoot
  $manifest = Read-JsonFile (Join-Path $backupDir 'manifest.json')
  Assert (@($manifest.themesBefore).Count -gt 0) 'deploy manifest themesBefore must be non-empty'
  Assert ((Invoke-Rollback $target $backupDir) -eq 0) 'rollback should succeed'
  Assert-Originals $target
}

Check 'B mid-deploy failure leaves a usable manifest and rollback restores' {
  $iso = New-IsoState (Join-Path $work 'B'); $env:LOCALAPPDATA = $iso.localAppData
  $target = New-Target (Join-Path $work 'B/CodexSkin') (Join-Path $work 'B')
  $code = Invoke-Deploy $target (Join-Path $work 'B-backup') @('-SimulateFailureAt', '3')
  Assert ($code -ne 0) 'deploy should fail when file #3 write is simulated to fail'
  $backupDir = Get-LatestBackup (Join-Path $work 'B-backup')
  $manifest = Read-JsonFile (Join-Path $backupDir 'manifest.json')
  Assert ($manifest.state -eq 'partial') ('manifest state should be partial, got ' + $manifest.state)
  Assert ((@($manifest.files | Where-Object { $_.status -eq 'written' })).Count -ge 1) 'some files should be recorded written'
  Assert ((Invoke-Rollback $target $backupDir) -eq 0) 'rollback after mid-deploy failure should succeed'
  Assert-Originals $target
}

Check 'C launch failure after full write still rolls back' {
  $iso = New-IsoState (Join-Path $work 'C'); $env:LOCALAPPDATA = $iso.localAppData
  $target = New-Target (Join-Path $work 'C/CodexSkin') (Join-Path $work 'C')
  $code = Invoke-Deploy $target (Join-Path $work 'C-backup') @('-Launch', '-SimulateLaunchFailure')
  Assert ($code -ne 0) 'deploy should fail on simulated launch failure'
  Assert-Deployed $target
  $backupDir = Get-LatestBackup (Join-Path $work 'C-backup')
  Assert ((Invoke-Rollback $target $backupDir) -eq 0) 'rollback after launch failure should succeed'
  Assert-Originals $target
}

Check 'D target path occupied by a directory is rejected before any change' {
  $iso = New-IsoState (Join-Path $work 'D'); $env:LOCALAPPDATA = $iso.localAppData
  $target = New-Target (Join-Path $work 'D/CodexSkin') (Join-Path $work 'D')
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $target.root 'app/app.js')
  $before = Get-Sha256 (Join-Path $target.root 'launcher.ps1')
  $code = Invoke-Deploy $target (Join-Path $work 'D-backup') $null
  Assert ($code -ne 0) 'deploy should reject a directory occupying a target path'
  Assert ((Get-Sha256 (Join-Path $target.root 'launcher.ps1')) -eq $before) 'launcher must be untouched'
}

Check 'E rollback rejects an out-of-whitelist path without deleting a sentinel' {
  $iso = New-IsoState (Join-Path $work 'E'); $env:LOCALAPPDATA = $iso.localAppData
  $targetRoot = Join-Path $work 'E/CodexSkin'
  $null = New-Item -ItemType Directory -Force -Path $targetRoot
  $sentinel = Join-Path $work 'E/sentinel.txt'
  [IO.File]::WriteAllText($sentinel, 'keep-me', (New-Object Text.UTF8Encoding($false)))
  $backupDir = Join-Path $work 'E-backup/deploy-evil'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $backupDir 'files')
  $files = @(); $i = 0
  foreach ($rel in @(Get-AllowedFiles)) {
    $i++; $p = $rel
    if ($i -eq 1) { $p = '../sentinel.txt' }
    $files += [ordered]@{ path = $p; targetExists = $false; status = 'pending'; sourceSha256 = ('0' * 64); targetSha256 = $null }
  }
  $manifest = [ordered]@{ mode = 'apply'; state = 'completed'; targetRoot = $targetRoot; backupDir = $backupDir; files = $files; themesBefore = @() }
  Write-JsonAtomic (Join-Path $backupDir 'manifest.json') $manifest
  $code = Invoke-Rollback ([ordered]@{ root = $targetRoot }) $backupDir
  Assert ($code -ne 0) 'rollback should reject an out-of-whitelist traversal path'
  Assert (Test-Path -LiteralPath $sentinel -PathType Leaf) 'sentinel must not be deleted'
}

Check 'F rollback rejects duplicate whitelist paths' {
  $iso = New-IsoState (Join-Path $work 'F'); $env:LOCALAPPDATA = $iso.localAppData
  $targetRoot = Join-Path $work 'F/CodexSkin'
  $null = New-Item -ItemType Directory -Force -Path $targetRoot
  $backupDir = Join-Path $work 'F-backup/deploy-dup'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $backupDir 'files')
  $files = @()
  foreach ($rel in @(Get-AllowedFiles)) { $files += [ordered]@{ path = $rel; targetExists = $false; status = 'pending'; sourceSha256 = ('0' * 64); targetSha256 = $null } }
  $files[1].path = $files[0].path
  $manifest = [ordered]@{ mode = 'apply'; state = 'completed'; targetRoot = $targetRoot; backupDir = $backupDir; files = $files; themesBefore = @() }
  Write-JsonAtomic (Join-Path $backupDir 'manifest.json') $manifest
  $code = Invoke-Rollback ([ordered]@{ root = $targetRoot }) $backupDir
  Assert ($code -ne 0) 'rollback should reject duplicate paths'
}

Check 'G rollback refuses to delete a new file that drifted since deploy' {
  $iso = New-IsoState (Join-Path $work 'G'); $env:LOCALAPPDATA = $iso.localAppData
  $target = New-Target (Join-Path $work 'G/CodexSkin') (Join-Path $work 'G')
  Assert ((Invoke-Deploy $target (Join-Path $work 'G-backup') $null) -eq 0) 'deploy should succeed'
  $backupDir = Get-LatestBackup (Join-Path $work 'G-backup')
  $drifted = Join-Path $target.root 'app/app.js'
  [IO.File]::AppendAllText($drifted, "`n// user edit", (New-Object Text.UTF8Encoding($false)))
  $driftedHash = Get-Sha256 $drifted
  $code = Invoke-Rollback $target $backupDir
  Assert ($code -ne 0) 'rollback should refuse to delete a drifted new file'
  Assert ((Get-Sha256 $drifted) -eq $driftedHash) 'drifted file must be left untouched'
}

Check 'H rollback refuses to overwrite an existing product file edited after deploy' {
  $iso = New-IsoState (Join-Path $work 'H'); $env:LOCALAPPDATA = $iso.localAppData
  $target = New-Target (Join-Path $work 'H/CodexSkin') (Join-Path $work 'H')
  Assert ((Invoke-Deploy $target (Join-Path $work 'H-backup') $null) -eq 0) 'deploy should succeed'
  $backupDir = Get-LatestBackup (Join-Path $work 'H-backup')
  $edited = Join-Path $target.root 'launcher.ps1'
  [IO.File]::AppendAllText($edited, "`n# USER EDIT", (New-Object Text.UTF8Encoding($false)))
  $editedHash = Get-Sha256 $edited
  $code = Invoke-Rollback $target $backupDir
  Assert ($code -ne 0) 'rollback should refuse to overwrite an existing file edited after deploy'
  Assert ((Get-Sha256 $edited) -eq $editedHash) 'edited existing file must be left untouched'
}

Check 'I rollback preserves themes with a non-empty snapshot' {
  $iso = New-IsoState (Join-Path $work 'I'); $env:LOCALAPPDATA = $iso.localAppData; $state = $iso.stateRoot
  $target = New-Target (Join-Path $work 'I/CodexSkin') (Join-Path $work 'I')
  Assert ((Invoke-Deploy $target (Join-Path $work 'I-backup') $null) -eq 0) 'deploy should succeed'
  $backupDir = Get-LatestBackup (Join-Path $work 'I-backup')
  $deployManifest = Read-JsonFile (Join-Path $backupDir 'manifest.json')
  Assert (@($deployManifest.themesBefore).Count -gt 0) 'deploy manifest themesBefore must be non-empty'
  $newTheme = Join-Path $state 'themes/theme-c'
  $null = New-Item -ItemType Directory -Force -Path $newTheme
  [IO.File]::WriteAllText((Join-Path $newTheme 'theme.json'), '{"id":"theme-c","name":"theme-c"}', (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $newTheme 'art.png'), 'PNGDATA-theme-c', (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText((Join-Path $state 'active-theme/theme.json'), '{"id":"theme-c","name":"theme-c"}', (New-Object Text.UTF8Encoding($false)))
  $code = Invoke-Rollback $target $backupDir
  Assert ($code -eq 0) ('rollback should succeed with a new user theme; got ' + $code)
  $rollResult = Read-JsonFile (Join-Path $backupDir 'rollback-result.json')
  Assert (@($rollResult.themesAtRollbackStart).Count -gt 0) 'rollback snapshot must be non-empty'
  $paths = @($rollResult.themesAtRollbackStart | ForEach-Object { $_.path })
  Assert (($paths -contains 'themes/theme-c/theme.json') -or (@($paths | Where-Object { $_ -like 'themes/theme-*' }).Count -ge 3)) 'rollback snapshot must include the saved themes'
  Assert (@($paths | Where-Object { $_ -like 'active-theme/*' }).Count -ge 1) 'rollback snapshot must include active-theme files'
  Assert (Test-Path -LiteralPath (Join-Path $newTheme 'theme.json') -PathType Leaf) 'new theme must be preserved'
  Assert ((Read-JsonFile (Join-Path $state 'active-theme/theme.json')).id -eq 'theme-c') 'current selection must be preserved'
  Assert-Originals $target
}

Write-Output ''
if ($failures -gt 0) { Write-Output ('SCENARIO FAILURES=' + $failures); exit 1 }
Write-Output 'ALL REHEARSAL SCENARIOS PASS'
Write-Output ('Evidence: ' + $work)
exit 0
