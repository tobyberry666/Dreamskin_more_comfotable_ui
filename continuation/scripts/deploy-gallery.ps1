# Codex Skin Gallery - minimal deploy (dry run by default)
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
[CmdletBinding()]
param(
  [string]$SourceRoot = 'D:\Dirty_work\codex-skin-audit\source',
  [string]$TargetRoot = 'D:\CodexSkin',
  [string]$BackupRoot = 'D:\Dirty_work\codex-skin-audit\continuation\backup',
  [string]$ShortcutPath = '',
  [int]$HelperPort = 9336,
  [switch]$Apply,
  [switch]$Launch,
  [int]$HealthTimeoutSeconds = 30,
  # Rehearsal-only fault injection. -1 = disabled.
  [int]$SimulateFailureAt = -1,
  [switch]$SimulateLaunchFailure
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gallery-maintenance-common.ps1')
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'

function Assert($condition, $message) { if (-not $condition) { throw ('ASSERT: ' + $message) } }

$manifest = $null
$manifestPath = $null
try {
  Assert (Test-Path -LiteralPath $TargetRoot -PathType Container) ('target root missing: ' + $TargetRoot)
  Assert (Test-Path -LiteralPath (Join-Path $TargetRoot 'launcher.ps1') -PathType Leaf) 'target launcher missing: not the expected gallery install'
  if (-not $ShortcutPath) {
    $marker = -join ([char[]]@(0x76AE, 0x80A4, 0x5ECA))
    $ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ('TOOls\Codex ' + $marker + '.lnk')
  }
  Assert (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) ('shortcut missing: ' + $ShortcutPath)
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  Assert ($shortcut.TargetPath -match 'powershell\.exe$') ('unexpected shortcut target: ' + $shortcut.TargetPath)
  $expectedLauncher = Join-Path $TargetRoot 'launcher.ps1'
  Assert ($shortcut.Arguments -match [regex]::Escape($expectedLauncher)) ('shortcut does not launch the expected launcher: ' + $shortcut.Arguments)

  $plan = @()
  foreach ($relative in @(Get-AllowedFiles)) {
    $source = Join-Path $SourceRoot ($relative.Replace('/', '\'))
    Assert (Test-Path -LiteralPath $source -PathType Leaf) ('source file missing: ' + $source)
    $target = Assert-UnderRoot (Join-Path $TargetRoot ($relative.Replace('/', '\'))) $TargetRoot ('target ' + $relative)
    Assert-NoReparse $target $TargetRoot
    $targetIsDirectory = (Test-Path -LiteralPath $target -PathType Container)
    Assert (-not $targetIsDirectory) ('target path is occupied by a directory: ' + $target)
    $targetExists = (Test-Path -LiteralPath $target -PathType Leaf)
    $plan += [ordered]@{
      path = $relative
      source = $source
      sourceSha256 = (Get-Sha256 $source)
      target = $target
      targetExists = $targetExists
      targetSha256 = $(if ($targetExists) { Get-Sha256 $target } else { $null })
      bytes = (Get-Item -LiteralPath $source).Length
      status = 'pending'
      writtenAt = $null
      deployedSha256 = $null
    }
  }

  $themesBefore = Get-ThemeSnapshot $stateRoot
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
  $backupDir = Join-Path $BackupRoot ('deploy-' + $stamp)
  $manifestPath = Join-Path $backupDir 'manifest.json'
  $manifest = [ordered]@{
    mode = 'apply'
    state = 'prepared'
    startedAt = (Get-Date).ToString('o')
    updatedAt = (Get-Date).ToString('o')
    sourceRoot = $SourceRoot
    targetRoot = $TargetRoot
    shortcutPath = $ShortcutPath
    backupDir = $backupDir
    helperPort = $HelperPort
    helperPid = $null
    helperIdentity = $null
    stoppedHelperPid = $null
    files = $plan
    themesBefore = $themesBefore
    launchRequested = [bool]$Launch
    launchFailed = $false
    error = $null
  }

  if (-not $Apply) {
    Write-Output ($manifest | ConvertTo-Json -Depth 8)
    Write-Output 'DRY RUN ONLY: pass -Apply to back up and deploy.'
    exit 0
  }

  # ---- 1. Back up existing product files (before any change) ----------
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $backupDir 'files')
  foreach ($item in $manifest.files) {
    if ($item.targetExists) {
      $destination = Assert-UnderRoot (Join-Path (Join-Path $backupDir 'files') ($item.path.Replace('/', '\'))) (Join-Path $backupDir 'files') ('backup ' + $item.path)
      $parent = Split-Path -Parent $destination
      if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
      Copy-Item -LiteralPath $item.target -Destination $destination -Force
      Assert ((Get-Sha256 $destination) -eq $item.targetSha256) ('backup hash mismatch: ' + $item.path)
    }
  }

  # ---- 2. Persist and re-verify the recovery manifest before any change ----
  Write-JsonAtomic $manifestPath $manifest
  $reread = Read-JsonFile $manifestPath
  Assert ($reread.state -eq 'prepared') 'manifest re-read state mismatch'
  Assert (@($reread.files).Count -eq @(Get-AllowedFiles).Count) 'manifest re-read file count mismatch'
  Assert ($reread.backupDir -eq $backupDir) 'manifest re-read backupDir mismatch'
  foreach ($relative in @(Get-AllowedFiles)) {
    $found = @($reread.files | Where-Object { $_.path -eq $relative })
    Assert ($found.Count -eq 1) ('manifest re-read missing entry: ' + $relative)
  }

  # ---- 3. Verify helper identity and maintenance admission before stopping ----
  $health = Get-HelperHealth $HelperPort
  $manifest.healthBefore = $health
  $helperPid = Get-ListenerPid $HelperPort
  $expectedHelper = Join-Path $TargetRoot 'helper\gallery-helper.js'
  $allowedNode = @(Get-AllowedNodeExecutables)
  $firstIdentity = $null
  $admission = $null
  if ($helperPid) {
    $firstIdentity = Test-HelperIdentity $helperPid $expectedHelper $allowedNode
    if (-not $firstIdentity.ok) {
      $manifest.state = 'aborted'
      $manifest.error = ('helper identity unverified: ' + $firstIdentity.reason)
      Write-JsonAtomic $manifestPath $manifest
      throw ('refusing to stop helper pid ' + $helperPid + ': ' + $firstIdentity.reason)
    }
    $admission = Assert-MaintenanceAdmission $HelperPort 'deploy'
    $manifest.helperPid = $helperPid
    $manifest.helperIdentity = $firstIdentity
    $manifest.maintenanceLatch = [string]$admission.latch
  }
  $manifest.state = 'partial'
  Write-JsonAtomic $manifestPath $manifest

  # ---- 4. Re-confirm the same instance, then stop the verified helper ----
  if ($helperPid) {
    $latchEngaged = ($admission -and ([string]$admission.latch -eq 'set'))
    try {
      $secondIdentity = Test-HelperIdentity $helperPid $expectedHelper $allowedNode
      $currentPid = Get-ListenerPid $HelperPort
      $same = Test-HelperInstanceUnchanged $firstIdentity $secondIdentity $currentPid
      if (-not $same.ok) {
        $manifest.state = 'aborted'
        $manifest.error = ('helper instance changed before stop: ' + $same.reason)
        Write-JsonAtomic $manifestPath $manifest
        throw ('refusing to stop helper pid ' + $helperPid + ': ' + $same.reason)
      }
      Stop-Process -Id $helperPid -Force
      for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        if (-not (Get-ListenerPid $HelperPort)) { break }
      }
      Assert (-not (Get-ListenerPid $HelperPort)) ('port ' + $HelperPort + ' did not close after stopping the helper')
      $manifest.stoppedHelperPid = $helperPid
      $manifest.stoppedHelperAt = (Get-Date).ToString('o')
      $manifest.updatedAt = (Get-Date).ToString('o')
      Write-JsonAtomic $manifestPath $manifest
    } catch {
      if ($latchEngaged) { try { $null = Set-MaintenanceLatch $HelperPort $false } catch { } }
      throw
    }
  }

  # ---- 5. Write product files with per-file progress ----
  $index = 0
  foreach ($item in $manifest.files) {
    $index++
    if ($SimulateFailureAt -gt 0 -and $index -eq $SimulateFailureAt) {
      throw ('SIMULATED failure before writing file #' + $index + ' ' + $item.path)
    }
    $item.status = 'writing'
    $manifest.updatedAt = (Get-Date).ToString('o')
    Write-JsonAtomic $manifestPath $manifest
    $parent = Split-Path -Parent $item.target
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
    $staging = $item.target + '.deploy-' + $stamp + '.tmp'
    Copy-Item -LiteralPath $item.source -Destination $staging -Force
    # Atomic replace: the target is either the original or the full deployed bytes, never a partial copy.
    if (Test-Path -LiteralPath $item.target -PathType Leaf) {
      $atomicBackup = $staging + '.bak'
      try { [IO.File]::Replace($staging, $item.target, $atomicBackup) }
      finally { if ([IO.File]::Exists($atomicBackup)) { [IO.File]::Delete($atomicBackup) } }
    } else {
      [IO.File]::Move($staging, $item.target)
    }
    if ([IO.File]::Exists($staging)) { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    Assert ((Get-Sha256 $item.target) -eq $item.sourceSha256) ('deployed hash mismatch: ' + $item.path)
    $item.status = 'written'
    $item.deployedSha256 = $item.sourceSha256
    $item.writtenAt = (Get-Date).ToString('o')
    $manifest.updatedAt = (Get-Date).ToString('o')
    Write-JsonAtomic $manifestPath $manifest
  }
  $manifest.deployedAt = (Get-Date).ToString('o')

  # ---- 6. Deployment must not touch the real theme library ----
  $themesAfter = Get-ThemeSnapshot $stateRoot
  $beforeJson = ($themesBefore | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join '|'
  $afterJson = ($themesAfter | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join '|'
  Assert ($beforeJson -eq $afterJson) 'theme library or active theme changed during deployment'
  $manifest.themesAfter = $themesAfter
  $manifest.state = 'completed'
  $manifest.updatedAt = (Get-Date).ToString('o')
  Write-JsonAtomic $manifestPath $manifest

  # ---- 7. Optional launch and health confirmation ----
  if ($Launch) {
    if ($SimulateLaunchFailure) { throw 'SIMULATED launch failure' }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $TargetRoot 'launcher.ps1')) -WorkingDirectory $TargetRoot | Out-Null
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    $newHealth = $null
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 500
      $newHealth = Get-HelperHealth $HelperPort
      if ($newHealth -and $newHealth.version -eq 2) { break }
    }
    if (-not ($newHealth -and $newHealth.version -eq 2)) { throw 'new helper did not report version 2 health' }
    $manifest.healthAfter = $newHealth
    $manifest.updatedAt = (Get-Date).ToString('o')
    Write-JsonAtomic $manifestPath $manifest
  }

  Write-Output ($manifest | ConvertTo-Json -Depth 8)
  Write-Output ('BACKUP: ' + $backupDir)
  exit 0
} catch {
  $message = $_.Exception.Message
  if ($manifest -and $manifestPath) {
    try {
      $manifest.updatedAt = (Get-Date).ToString('o')
      if (-not $manifest.error) { $manifest.error = $message }
      if ($manifest.state -ne 'completed' -and $manifest.state -ne 'aborted') { $manifest.state = 'partial' }
      if ($Launch -and $message -match 'launch') { $manifest.launchFailed = $true }
      Write-JsonAtomic $manifestPath $manifest
    } catch { }
  }
  Write-Error ('DEPLOY FAILED: ' + $message)
  exit 1
}
