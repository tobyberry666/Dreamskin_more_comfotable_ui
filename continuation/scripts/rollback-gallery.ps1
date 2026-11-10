# Codex Skin Gallery - roll back a deploy made by deploy-gallery.ps1 (dry run by default)
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BackupDir,
  [string]$TargetRoot = 'D:\CodexSkin',
  [int]$HelperPort = 9336,
  [switch]$Apply,
  [switch]$Launch,
  [int]$HealthTimeoutSeconds = 30
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gallery-maintenance-common.ps1')
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'

function Assert($condition, $message) { if (-not $condition) { throw ('ASSERT: ' + $message) } }

$result = $null
try {
  $manifestPath = Join-Path $BackupDir 'manifest.json'
  Assert (Test-Path -LiteralPath $manifestPath -PathType Leaf) ('backup manifest missing: ' + $manifestPath)
  $manifest = Read-JsonFile $manifestPath
  Assert ($manifest.mode -eq 'apply') 'backup manifest is not from an applied deployment'
  $allowedStates = @('prepared', 'partial', 'completed', 'aborted')
  Assert ($allowedStates -contains [string]$manifest.state) ('unexpected manifest state: ' + [string]$manifest.state)
  Assert (([IO.Path]::GetFullPath([string]$manifest.targetRoot)) -ieq ([IO.Path]::GetFullPath($TargetRoot))) ('backup belongs to ' + [string]$manifest.targetRoot + ', not ' + $TargetRoot)
  Assert (([IO.Path]::GetFullPath([string]$manifest.backupDir)) -ieq ([IO.Path]::GetFullPath($BackupDir))) 'manifest backupDir does not match BackupDir'

  # ---- 1. Independent fixed whitelist validation (before any change) ----
  $allowed = Get-AllowedFiles
  $manifestFiles = @($manifest.files)
  Assert ($manifestFiles.Count -eq $allowed.Count) ('manifest must list exactly ' + $allowed.Count + ' files, found ' + $manifestFiles.Count)
  $seen = @{}
  foreach ($item in $manifestFiles) {
    $raw = [string]$item.path
    Assert (-not [string]::IsNullOrWhiteSpace($raw)) 'manifest contains an empty path'
    Assert (-not [IO.Path]::IsPathRooted($raw)) ('manifest contains an absolute path: ' + $raw)
    $norm = $raw.Replace('\', '/')
    foreach ($segment in @($norm -split '/')) {
      Assert (-not ($segment -eq '..' -or $segment -eq '.' -or $segment -eq '')) ('manifest path has relative traversal: ' + $raw)
    }
    Assert ($allowed -ccontains $norm) ('manifest path is not in the fixed whitelist: ' + $raw)
    $key = $norm.ToLowerInvariant()
    Assert (-not $seen.ContainsKey($key)) ('manifest has a duplicate path: ' + $raw)
    $seen[$key] = $true
  }
  foreach ($required in $allowed) {
    Assert ($seen.ContainsKey($required.ToLowerInvariant())) ('manifest is missing whitelist entry: ' + $required)
  }

  # ---- 2. Resolve and verify every path/hash before stopping or writing ----
  $backupFilesRoot = Join-Path $BackupDir 'files'
  $plan = @()
  foreach ($item in $manifestFiles) {
    $norm = ([string]$item.path).Replace('\', '/')
    $targetPath = Assert-UnderRoot (Join-Path $TargetRoot ($norm.Replace('/', '\'))) $TargetRoot ('target ' + $norm)
    Assert-NoReparse $targetPath $TargetRoot
    $backupFile = Assert-UnderRoot (Join-Path $backupFilesRoot ($norm.Replace('/', '\'))) $backupFilesRoot ('backup ' + $norm)
    Assert-NoReparse $backupFile $BackupDir
    $restore = [bool]$item.targetExists
    $status = [string]$item.status
    $targetExists = (Test-Path -LiteralPath $targetPath -PathType Leaf)
    $targetSha = $(if ($targetExists) { Get-Sha256 $targetPath } else { $null })
    $originalSha = [string]$item.targetSha256
    $deployedSha = [string]$item.sourceSha256
    if ($restore) {
      Assert (Test-Path -LiteralPath $backupFile -PathType Leaf) ('backup file missing: ' + $norm)
      Assert ((Get-Sha256 $backupFile) -eq $originalSha) ('backup hash mismatch: ' + $norm)
      Assert ($targetExists) ('refusing to restore a file that is unexpectedly missing: ' + $norm)
      if ($status -eq 'written') {
        Assert ($targetSha -eq $deployedSha) ('refusing to restore a file changed outside this deploy (hash drift): ' + $norm)
      } elseif ($status -eq 'pending') {
        Assert ($targetSha -eq $originalSha) ('refusing to restore a file changed outside this deploy (hash drift): ' + $norm)
      } elseif ($status -eq 'writing') {
        # A deploy writes atomically, so an interrupted 'writing' file is either still the
        # original bytes or already the fully-deployed bytes. Anything else is unknown and
        # must be rejected before stopping or writing.
        Assert (-not [string]::IsNullOrWhiteSpace($deployedSha)) ('manifest missing deployed hash for writing file: ' + $norm)
        Assert (($targetSha -eq $originalSha) -or ($targetSha -eq $deployedSha)) ('refusing to restore a file whose content is not provably from this deploy (hash drift): ' + $norm)
      } else {
        throw ('ASSERT: unknown per-file status for ' + $norm + ': ' + $status)
      }
    } else {
      Assert (-not [string]::IsNullOrWhiteSpace($deployedSha)) ('manifest missing deployed hash for new file: ' + $norm)
      if ($targetExists) {
        if ($status -eq 'written' -or $status -eq 'writing') {
          Assert ($targetSha -eq $deployedSha) ('refusing to delete a new file changed since deploy (hash drift): ' + $norm)
        } else {
          throw ('ASSERT: refusing to delete a file created outside this deploy: ' + $norm + ' status=' + $status)
        }
      } elseif ($status -eq 'written' -or $status -eq 'writing') {
        # already absent: nothing to delete
      } elseif ($status -ne 'pending') {
        throw ('ASSERT: unknown per-file status for new file ' + $norm + ': ' + $status)
      }
    }
    $plan += [ordered]@{
      path = $norm
      target = $targetPath
      backup = $backupFile
      restore = $restore
      status = $status
      expectedSha256 = $(if ($restore) { $originalSha } else { $null })
      expectedDeployed = $(if ($restore) { $null } else { $deployedSha })
      targetExists = $targetExists
      targetSha256 = $targetSha
    }
  }

  $themesAtRollbackStart = Get-ThemeSnapshot $stateRoot
  $result = [ordered]@{
    mode = $(if ($Apply) { 'apply' } else { 'dry-run' })
    startedAt = (Get-Date).ToString('o')
    backupDir = $BackupDir
    targetRoot = $TargetRoot
    helperPort = $HelperPort
    manifestState = [string]$manifest.state
    files = $plan
    themesAtRollbackStart = $themesAtRollbackStart
  }

  if (-not $Apply) {
    Write-Output ($result | ConvertTo-Json -Depth 8)
    Write-Output 'DRY RUN ONLY: pass -Apply to restore the backed-up product files.'
    exit 0
  }

  # ---- 3. Verify helper identity and maintenance admission before stopping ----
  $health = Get-HelperHealth $HelperPort
  $result.healthBefore = $health
  $helperPid = Get-ListenerPid $HelperPort
  $expectedHelper = Join-Path $TargetRoot 'helper\gallery-helper.js'
  $allowedNode = @(Get-AllowedNodeExecutables)
  $firstIdentity = $null
  $admission = $null
  if ($helperPid) {
    $firstIdentity = Test-HelperIdentity $helperPid $expectedHelper $allowedNode
    if (-not $firstIdentity.ok) { throw ('refusing to stop helper pid ' + $helperPid + ': ' + $firstIdentity.reason) }
    $admission = Assert-MaintenanceAdmission $HelperPort 'rollback'
    $result.maintenanceLatch = [string]$admission.latch
    $latchEngaged = ([string]$admission.latch -eq 'set')
    try {
      $secondIdentity = Test-HelperIdentity $helperPid $expectedHelper $allowedNode
      $currentPid = Get-ListenerPid $HelperPort
      $same = Test-HelperInstanceUnchanged $firstIdentity $secondIdentity $currentPid
      if (-not $same.ok) { throw ('helper instance changed before stop: ' + $same.reason) }
      Stop-Process -Id $helperPid -Force
      for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        if (-not (Get-ListenerPid $HelperPort)) { break }
      }
      Assert (-not (Get-ListenerPid $HelperPort)) ('port ' + $HelperPort + ' did not close after stopping the helper')
      $result.stoppedHelperPid = $helperPid
    } catch {
      if ($latchEngaged) { try { $null = Set-MaintenanceLatch $HelperPort $false } catch { } }
      throw
    }
  }

  # ---- 4. Restore original files and delete only untouched newly-added files ----
  foreach ($item in $plan) {
    if ($item.restore) {
      $parent = Split-Path -Parent $item.target
      if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
      $staging = $item.target + '.rollback.tmp'
      Copy-Item -LiteralPath $item.backup -Destination $staging -Force
      if (Test-Path -LiteralPath $item.target -PathType Leaf) {
        $atomicBackup = $staging + '.bak'
        try { [IO.File]::Replace($staging, $item.target, $atomicBackup) }
        finally { if ([IO.File]::Exists($atomicBackup)) { [IO.File]::Delete($atomicBackup) } }
      } else { [IO.File]::Move($staging, $item.target) }
      if ([IO.File]::Exists($staging)) { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
      Assert ((Get-Sha256 $item.target) -eq $item.expectedSha256) ('restored hash mismatch: ' + $item.path)
    } elseif ($item.targetExists) {
      Assert ((Get-Sha256 $item.target) -eq [string]$item.targetSha256) ('target changed during rollback: ' + $item.path)
      Remove-Item -LiteralPath $item.target -Force
    }
  }
  $result.restoredAt = (Get-Date).ToString('o')

  # ---- 5. Rollback must preserve the live theme library captured at start ----
  $themesAfter = Get-ThemeSnapshot $stateRoot
  $startJson = ($themesAtRollbackStart | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join '|'
  $afterJson = ($themesAfter | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join '|'
  Assert ($startJson -eq $afterJson) 'rollback changed the live theme library'
  $result.themesAfter = $themesAfter

  # ---- 6. Optional launch and legacy-health confirmation ----
  if ($Launch) {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $TargetRoot 'launcher.ps1')) -WorkingDirectory $TargetRoot | Out-Null
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    $oldHealth = $null
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 500
      $oldHealth = Get-HelperHealth $HelperPort
      if ($oldHealth -and $oldHealth.ok -eq $true -and $null -eq $oldHealth.version) { break }
    }
    Assert ($oldHealth -and $oldHealth.ok -eq $true -and $null -eq $oldHealth.version) 'restored helper did not report legacy health'
    $result.healthAfter = $oldHealth
  }

  $result.finishedAt = (Get-Date).ToString('o')
  Write-JsonAtomic (Join-Path $BackupDir 'rollback-result.json') $result
  Write-Output ($result | ConvertTo-Json -Depth 8)
  exit 0
} catch {
  $message = $_.Exception.Message
  try {
    $failure = [ordered]@{ mode = $(if ($Apply) { 'apply' } else { 'dry-run' }); failedAt = (Get-Date).ToString('o'); backupDir = $BackupDir; error = $message }
    Write-JsonAtomic (Join-Path $BackupDir 'rollback-failure.json') $failure
  } catch { }
  Write-Error ('ROLLBACK FAILED: ' + $message)
  exit 1
}
