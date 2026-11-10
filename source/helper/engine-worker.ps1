[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$RequestPath,
  [Parameter(Mandatory=$true)][string]$ResultPath,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'),
  [string]$EngineRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin/engine')
)
# ASCII source is intentional: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$work = $null
function Write-AtomicUtf8([string]$Path, [string]$Text) {
  $full = [IO.Path]::GetFullPath($Path)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
  $temporary = $full + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [IO.File]::WriteAllText($temporary, $Text, $utf8)
    if ([IO.File]::Exists($full)) {
      $backup = $temporary + '.bak'
      try { [IO.File]::Replace($temporary, $full, $backup) }
      finally { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } }
    }
    else { [IO.File]::Move($temporary, $full) }
  } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
try {
  $request = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RequestPath), [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($null -eq $request -or $request -is [array] -or $request -is [string]) { throw 'Request must be a JSON object.' }
  if ($request.action -cnotin @('import', 'apply')) { throw 'Unsupported engine action.' }
  . (Join-Path $EngineRoot 'scripts/common-windows.ps1')
  . (Join-Path $EngineRoot 'scripts/theme-windows.ps1')
  $StateRoot = [IO.Path]::GetFullPath($StateRoot)
  if ($request.action -ceq 'import') {
    if (($request.expectedBytes -isnot [int] -and $request.expectedBytes -isnot [long]) -or
      $request.expectedBytes -lt 1 -or $request.expectedBytes -gt 32MB -or
      $request.expectedSha256 -isnot [string] -or $request.expectedSha256 -cnotmatch '^[a-f0-9]{64}$') {
      throw 'Import requires expectedBytes and a lowercase expectedSha256 hash.'
    }
    if ($null -ne $request.adaptWindows -and $request.adaptWindows -isnot [bool]) { throw 'adaptWindows must be boolean.' }
    $archive = [IO.Path]::GetFullPath([string]$request.archivePath)
    # Verify a private snapshot, then pass that same snapshot to the engine.
    $work = Join-Path ([IO.Path]::GetTempPath()) ('gallery-engine-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $snapshot = Join-Path $work 'original.zip'
    [IO.File]::Copy($archive, $snapshot)
    if ((Get-Item -LiteralPath $snapshot).Length -ne $request.expectedBytes) { throw 'Archive size does not match expectedBytes.' }
    $actualHash = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $request.expectedSha256) { throw 'Archive SHA256 hash does not match expectedSha256.' }
    $importArchive = $snapshot
    $importBytes = [long]$request.expectedBytes
    $importHash = $actualHash
    if ($request.adaptWindows -eq $true) {
      $pinnedHash = '14dadf429cfefdc50d48ac0b3e2f8febb5cb379a359e9300d1f20ee3cc864c40'
      if ($importBytes -ne 631581 -or $actualHash -cne $pinnedHash) { throw 'Windows adaptation is restricted to the pinned original rainwashed-celadon archive.' }
      $source = Join-Path $work 'source'
      [IO.Directory]::CreateDirectory($source) | Out-Null
      $source = Expand-DreamSkinThemeZipSecurely -ArchivePath $snapshot -DestinationRoot $source -ExpectedArchiveBytes $importBytes -ExpectedArchiveSha256 $importHash
      $node = Get-DreamSkinNodeRuntime
      $validator = Join-Path $EngineRoot 'assets/theme-package-validator.mjs'
      $validated = Join-Path $work 'macos-validated'
      [IO.Directory]::CreateDirectory($validated) | Out-Null
      $validation = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @($validator, '--source', $source, '--stage', $validated, '--platform', 'macos', '--client-version', ([IO.File]::ReadAllText((Join-Path $EngineRoot 'VERSION')).Trim())) -SeparateStderr
      if ($validation.ExitCode -ne 0) { throw ('Original macOS package validation failed: ' + (($validation.Output + $validation.ErrorOutput) -join ' ')) }
      $manifestPath = Join-Path $source 'manifest.json'
      $originalManifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
      $manifest = $originalManifest | ConvertFrom-Json
      $themePath = Join-Path $source 'theme.json'
      $theme = [IO.File]::ReadAllText($themePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($manifest.themeId -cne 'guiming.ink.rainwashed-celadon' -or $theme.id -cne $manifest.themeId) { throw 'Pinned source theme identity mismatch.' }
      $theme.id += '-windows-local'
      $localLabel = -join ([char[]]@(0x672c,0x5730,0x9002,0x914d))
      $theme.name += ' / Windows ' + $localLabel
      $manifest.themeId = $theme.id
      $manifest.platforms = @('windows')
      $manifest.provenance.summary += ' Local Windows adaptation; source archive SHA256: ' + $pinnedHash + '. Original publisher and license retained.'
      [IO.File]::WriteAllText($themePath, ($theme | ConvertTo-Json -Depth 32), $utf8)
      foreach ($entry in $manifest.files) {
        $payload = Join-Path $source $entry.path
        $entry.bytes = (Get-Item -LiteralPath $payload).Length
        $entry.sha256 = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
      }
      $adaptedManifest = $manifest | ConvertTo-Json -Depth 32
      [IO.File]::WriteAllText($manifestPath, $adaptedManifest, $utf8)
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $importArchive = Join-Path $work 'windows-local.zip'
      [IO.Compression.ZipFile]::CreateFromDirectory($source, $importArchive)
      $importBytes = (Get-Item -LiteralPath $importArchive).Length
      $importHash = (Get-FileHash -LiteralPath $importArchive -Algorithm SHA256).Hash.ToLowerInvariant()
      # Preserve provenance in app downloads, never in the engine runtime-only directory.
      $provenance = Join-Path (Split-Path -Parent $PSScriptRoot) ('data/downloads/' + $pinnedHash)
      Assert-DreamSkinNoReparseComponents -Path $provenance
      [IO.Directory]::CreateDirectory($provenance) | Out-Null
      $originalCopy = Join-Path $provenance 'original.zip'
      if (-not [IO.File]::Exists($originalCopy)) { [IO.File]::Copy($snapshot, $originalCopy) }
      elseif ((Get-FileHash -LiteralPath $originalCopy -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pinnedHash) { throw 'Stored original archive provenance hash mismatch.' }
      Write-AtomicUtf8 (Join-Path $provenance 'source-manifest.json') $originalManifest
      Write-AtomicUtf8 (Join-Path $provenance 'windows-local-manifest.json') $adaptedManifest
    }
    $imported = Import-DreamSkinThemeZip -ArchivePath $importArchive -StateRoot $StateRoot -ExpectedArchiveBytes $importBytes -ExpectedArchiveSha256 $importHash
    $savedRoot = (Get-DreamSkinThemePaths -StateRoot $StateRoot).Saved
    if (-not (Test-DreamSkinThemePathWithin -Path $imported.Path -Root $savedRoot)) { throw 'Engine import did not resolve to an actual saved theme.' }
    $loaded = Read-DreamSkinTheme -ThemeDirectory $imported.Path
    if ([string]$loaded.Theme.id -cne [string]$imported.Id) { throw 'Engine import identity verification failed.' }
    $result = @{ok=$true;theme=@{id=[string]$imported.Id;name=[string]$imported.Name};message='Theme imported and saved.'}
  } else {
    $id = [string]$request.themeId
    if ($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or $id.EndsWith('.') -or (Test-DreamSkinWindowsReservedPathStem -Name $id)) { throw 'Invalid saved theme ID.' }
    $installedState = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
    if (-not (Test-DreamSkinPathEqual -Left $StateRoot -Right $installedState)) { throw 'Cannot apply isolated StateRoot to real Codex.' }
    $installedEngine = Join-Path $installedState 'engine'
    if (-not (Test-DreamSkinPathEqual -Left $EngineRoot -Right $installedEngine)) { throw 'Apply requires the installed engine.' }
    $savedRoot = (Get-DreamSkinThemePaths -StateRoot $StateRoot).Saved
    $directory = Join-Path $savedRoot $id
    if (-not (Test-DreamSkinThemePathWithin -Path $directory -Root $savedRoot)) { throw 'Saved theme ID must resolve within the actual theme library.' }
    $loaded = Read-DreamSkinTheme -ThemeDirectory $directory
    if ([string]$loaded.Theme.id -cne $id) { throw 'Saved theme ID does not match theme metadata.' }
    $token = [guid]::NewGuid().ToString('N')
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $EngineRoot 'scripts/start-dream-skin.ps1'),'-SavedThemeDirectory',$directory,'-RestartExisting','-ResultToken',$token)
    $process = Start-Process -FilePath "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList (ConvertTo-DreamSkinArgumentLine -Arguments $arguments) -WindowStyle Hidden -PassThru
    $process.WaitForExit()
    $startResult = Read-DreamSkinStartResult -StateRoot $StateRoot -Token $token
    if ($process.ExitCode -ne 0 -or $startResult.outcome -cne 'success') { throw ('Theme apply failed: ' + $startResult.category + ' (exit ' + $process.ExitCode + ').') }
    $result = @{ok=$true;theme=@{id=$id;name=[string]$loaded.Theme.name};message='Theme applied; engine verified rendered readiness.'}
  }
} catch {
  $result = @{ok=$false;message=$_.Exception.Message}
} finally {
  if ($work -and [IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-AtomicUtf8 $ResultPath ($result | ConvertTo-Json -Depth 8 -Compress)
if (-not $result.ok) { exit 1 }
