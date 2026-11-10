# Shared maintenance helpers for the Codex Skin Gallery deploy/rollback tools.
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
# Dot-source this file from deploy-gallery.ps1, rollback-gallery.ps1 and the tests.

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AllowedFiles {
  return @(
    'launcher.ps1',
    'app/index.html',
    'app/app.js',
    'app/styles.css',
    'helper/gallery-helper.js',
    'helper/engine-worker.ps1'
  )
}

function Normalize-PathForCompare([string]$Path) {
  if (-not $Path) { return $null }
  $full = [IO.Path]::GetFullPath($Path)
  return $full.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [char]'/', [char]'\'))
}

function Get-AllowedNodeExecutables {
  # Only the system Node and the installed DreamSkin runtimes are trusted; a file
  # merely named node.exe elsewhere must be rejected.
  $list = @()
  $system = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($system -and $system.Source) { $list += (Normalize-PathForCompare $system.Source) }
  $list += (Normalize-PathForCompare (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\engine\runtime\node\node.exe'))
  $list += (Normalize-PathForCompare (Join-Path $env:LOCALAPPDATA 'Programs\CodexDreamSkin\payload\runtime\node\node.exe'))
  return @($list | Where-Object { $_ } | Select-Object -Unique)
}

function Get-ListenerPid([int]$Port) {
  $pattern = '^\s*TCP\s+\S+:' + $Port + '\s+\S+\s+LISTENING\s+(\d+)\s*$'
  foreach ($line in @(netstat -ano)) {
    if ($line -match $pattern) { return [int]$Matches[1] }
  }
  return $null
}

function Split-CommandLine([string]$CommandLine) {
  # Tokenize respecting double quotes; enough to separate the node script argument.
  $result = @()
  foreach ($m in [regex]::Matches($CommandLine, '"([^"]*)"|(\S+)')) {
    if ($m.Groups[1].Success) { $result += $m.Groups[1].Value } else { $result += $m.Groups[2].Value }
  }
  return $result
}

function Get-ProcessRecord([int]$ProcessId) {
  try { return Get-CimInstance Win32_Process -Filter ('ProcessId=' + $ProcessId) -ErrorAction Stop }
  catch { return $null }
}

function Test-HelperCommandIdentity([string]$ExecutablePath, [string]$CommandLine, [string]$ExpectedScript, [string[]]$AllowedExecutables) {
  # Pure predicate: the executable must resolve to a trusted runtime path, and the
  # command line must name the expected helper script as its sole script argument.
  if (-not $ExecutablePath) { return [ordered]@{ ok = $false; reason = 'executable path unknown' } }
  $exeFull = Normalize-PathForCompare $ExecutablePath
  if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) { return [ordered]@{ ok = $false; reason = ('executable path missing: ' + $ExecutablePath) } }
  $allowed = @($AllowedExecutables | Where-Object { $_ } | ForEach-Object { Normalize-PathForCompare $_ })
  $trusted = $false
  foreach ($candidate in $allowed) { if ($candidate -and ($exeFull -ieq $candidate)) { $trusted = $true } }
  if (-not $trusted) { return [ordered]@{ ok = $false; reason = ('executable is not a trusted runtime path: ' + $ExecutablePath) } }
  $tokens = @(Split-CommandLine $CommandLine)
  if ($tokens.Count -lt 2) { return [ordered]@{ ok = $false; reason = 'command line has no script argument'; commandLine = $CommandLine } }
  $jsTokens = @($tokens | Where-Object { $_ -match '(?i)\.js$' })
  if ($jsTokens.Count -ne 1) { return [ordered]@{ ok = $false; reason = ('command line must contain exactly one .js script argument, found ' + $jsTokens.Count); commandLine = $CommandLine } }
  if (-not ($tokens[1] -match '(?i)\.js$')) { return [ordered]@{ ok = $false; reason = ('first argument after the runtime is not the script: ' + [string]$tokens[1]); commandLine = $CommandLine } }
  $resolved = $null
  try { $resolved = [IO.Path]::GetFullPath($tokens[1]) } catch { $resolved = $null }
  $expectedFull = [IO.Path]::GetFullPath($ExpectedScript)
  if (-not $resolved -or -not ($resolved -ieq $expectedFull)) {
    return [ordered]@{ ok = $false; reason = ('script argument does not resolve to the expected helper: ' + [string]$tokens[1]); commandLine = $CommandLine }
  }
  return [ordered]@{ ok = $true; executable = $ExecutablePath; commandLine = $CommandLine }
}

function Test-HelperIdentity([int]$ProcessId, [string]$ExpectedScript, [string[]]$AllowedExecutables) {
  $info = Get-ProcessRecord $ProcessId
  if ($null -eq $info) { return [ordered]@{ ok = $false; reason = 'process not found' } }
  $predicate = Test-HelperCommandIdentity ([string]$info.ExecutablePath) ([string]$info.CommandLine) $ExpectedScript $AllowedExecutables
  if (-not $predicate.ok) { return $predicate }
  return [ordered]@{
    ok = $true
    processId = $ProcessId
    executable = [string]$info.ExecutablePath
    commandLine = [string]$info.CommandLine
    creationDate = [string]$info.CreationDate
  }
}

function Test-HelperInstanceUnchanged($First, $Second, [int]$CurrentListenerPid) {
  # Confirms the two identity probes are the same complete, live instance still owning the port.
  if (-not $First -or -not $First.ok) { return [ordered]@{ ok = $false; reason = 'first identity probe not ok' } }
  if (-not $Second -or -not $Second.ok) { return [ordered]@{ ok = $false; reason = 'second identity probe not ok' } }
  foreach ($field in @('executable', 'commandLine', 'creationDate')) {
    if ([string]::IsNullOrWhiteSpace([string]$First.$field) -or [string]::IsNullOrWhiteSpace([string]$Second.$field)) {
      return [ordered]@{ ok = $false; reason = ('identity field is incomplete: ' + $field) }
    }
  }
  if ([int]$First.processId -ne [int]$Second.processId) { return [ordered]@{ ok = $false; reason = 'pid changed between probes' } }
  if ([string]$First.creationDate -ne [string]$Second.creationDate) { return [ordered]@{ ok = $false; reason = 'creation date changed (pid reused)' } }
  if ([string]$First.executable -ine [string]$Second.executable) { return [ordered]@{ ok = $false; reason = 'executable changed between probes' } }
  if ([string]$First.commandLine -cne [string]$Second.commandLine) { return [ordered]@{ ok = $false; reason = 'command line changed between probes' } }
  if (-not $CurrentListenerPid -or ([int]$CurrentListenerPid -le 0)) {
    return [ordered]@{ ok = $false; reason = 'no live listener owns the target port; refusing to stop an unproven instance' }
  }
  if ([int]$CurrentListenerPid -ne [int]$Second.processId) { return [ordered]@{ ok = $false; reason = 'current listener pid is not the verified instance' } }
  return [ordered]@{ ok = $true; reason = 'same instance' }
}

function Assert-UnderRoot([string]$Path, [string]$Root, [string]$Label) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $fullRoot = [IO.Path]::GetFullPath($Root)
  $sep = [string][IO.Path]::DirectorySeparatorChar
  $withSep = $fullRoot
  if (-not $withSep.EndsWith($sep)) { $withSep = $withSep + $sep }
  if (-not ($fullPath -ieq $fullRoot) -and -not $fullPath.StartsWith($withSep, [StringComparison]::OrdinalIgnoreCase)) {
    throw ('ASSERT: ' + $Label + ' escapes root: ' + $fullPath)
  }
  return $fullPath
}

function Assert-NoReparse([string]$Path, [string]$Root) {
  $fullRoot = [IO.Path]::GetFullPath($Root)
  $fullPath = [IO.Path]::GetFullPath($Path)
  $current = $fullRoot
  if (Test-Path -LiteralPath $current) {
    $item = Get-Item -LiteralPath $current -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('ASSERT: reparse point in path: ' + $current) }
  }
  if ($fullPath.Length -le $fullRoot.Length) { return }
  $relative = $fullPath.Substring($fullRoot.Length).TrimStart([char[]]@([IO.Path]::DirectorySeparatorChar, [char]'/', [char]'\'))
  foreach ($part in @($relative -split '[\\/]')) {
    if (-not $part) { continue }
    $current = Join-Path $current $part
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('ASSERT: reparse point in path: ' + $current) }
    }
  }
}

function Get-ThemeSnapshot([string]$StateRoot) {
  $items = @()
  foreach ($base in @((Join-Path $StateRoot 'themes'), (Join-Path $StateRoot 'active-theme'))) {
    if (-not (Test-Path -LiteralPath $base)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $base -Recurse -File | Sort-Object FullName)) {
      $relative = $file.FullName.Substring($StateRoot.Length + 1).Replace('\', '/')
      $items += [ordered]@{ path = $relative; bytes = $file.Length; sha256 = (Get-Sha256 $file.FullName) }
    }
  }
  return $items
}

function Get-HelperHealth([int]$Port) {
  try {
    $response = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/api/health') -UseBasicParsing -TimeoutSec 3
    return ($response.Content | ConvertFrom-Json)
  } catch { return $null }
}

function Get-MaintenanceJobState([int]$Port) {
  # Distinguish an old service that has no job API from a v2 query failure.
  try {
    $response = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/api/jobs/latest') -UseBasicParsing -TimeoutSec 3
    $body = $response.Content | ConvertFrom-Json
    return [ordered]@{ ok = $true; supported = $true; job = $body.job; error = $null }
  } catch {
    $status = $null
    try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { $status = $null }
    if ($status -eq 404) { return [ordered]@{ ok = $true; supported = $false; job = $null; error = $null } }
    return [ordered]@{ ok = $false; supported = $false; job = $null; error = $_.Exception.Message }
  }
}

function Set-MaintenanceLatch([int]$Port, [bool]$Enabled) {
  # Returns 'set' when the service accepted the latch, 'unsupported' for an old
  # service with no maintenance endpoint; throws on any other failure.
  $health = Get-HelperHealth $Port
  if (-not $health -or -not $health.token) { return 'unsupported' }
  $uri = 'http://127.0.0.1:' + $Port + '/api/maintenance'
  $headers = @{ 'X-Gallery-Token' = [string]$health.token; 'Content-Type' = 'application/json'; Origin = ('http://127.0.0.1:' + $Port) }
  $body = (@{ enabled = $Enabled } | ConvertTo-Json -Compress)
  try {
    $null = Invoke-WebRequest -Uri $uri -Method POST -UseBasicParsing -TimeoutSec 3 -Headers $headers -Body $body
    return 'set'
  } catch {
    $status = $null
    try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { $status = $null }
    if ($status -eq 404) { return 'unsupported' }
    throw ('maintenance latch request failed: ' + $_.Exception.Message)
  }
}

function Assert-MaintenanceAdmission([int]$Port, [string]$Action) {
  # Shared gate for deploy and rollback: refuses running/queued jobs, an unconfirmed
  # termination lock, an old-vs-v2 job-state ambiguity, then engages the service-side
  # latch so no new write task can be accepted between this check and the stop.
  $health = Get-HelperHealth $Port
  $listenerPid = Get-ListenerPid $Port
  $info = [ordered]@{ helperPid = $listenerPid; health = $health; latch = 'none' }
  if (-not $listenerPid) { return $info }
  $isV2 = ($health -and ($null -ne $health.version) -and ([int]$health.version -eq 2))
  $state = Get-MaintenanceJobState $Port
  if (-not $state.ok) { throw ('cannot verify helper job state on port ' + $Port + ': ' + $state.error) }
  if ($isV2 -and -not $state.supported) { throw 'v2 helper did not expose /api/jobs/latest; refusing to proceed blind' }
  if ($state.supported -and $state.job) {
    $status = [string]$state.job.status
    if (@('queued', 'running') -contains $status) { throw ('refusing ' + $Action + ': helper job ' + [string]$state.job.id + ' is ' + $status) }
    if ([bool]$state.job.terminationUnconfirmed) { throw ('refusing ' + $Action + ': helper holds an unconfirmed termination lock; restarting the helper is not a safe bypass') }
  }
  $latch = Set-MaintenanceLatch $Port $true
  $info.latch = $latch
  if ($isV2 -and $latch -ne 'set') { throw 'v2 helper did not accept the maintenance latch' }
  $state2 = Get-MaintenanceJobState $Port
  if (-not $state2.ok) {
    if ($latch -eq 'set') { try { $null = Set-MaintenanceLatch $Port $false } catch { } }
    throw ('job state query failed after engaging the maintenance latch: ' + $state2.error)
  }
  if ($state2.supported -and $state2.job) {
    $status2 = [string]$state2.job.status
    if ((@('queued', 'running') -contains $status2) -or [bool]$state2.job.terminationUnconfirmed) {
      if ($latch -eq 'set') { try { $null = Set-MaintenanceLatch $Port $false } catch { } }
      throw ('refusing ' + $Action + ': a write task appeared after the admission check (' + $status2 + ')')
    }
  }
  return $info
}

function Write-JsonAtomic([string]$Path, $Value) {
  $json = $Value | ConvertTo-Json -Depth 12
  $full = [IO.Path]::GetFullPath($Path)
  $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
  $temporary = $full + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
  if ([IO.File]::Exists($full)) {
    $backup = $temporary + '.bak'
    try { [IO.File]::Replace($temporary, $full, $backup) }
    finally { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } }
  } else { [IO.File]::Move($temporary, $full) }
}

function Read-JsonFile([string]$Path) {
  return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
