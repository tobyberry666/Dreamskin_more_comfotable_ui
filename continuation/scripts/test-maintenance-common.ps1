# Unit checks for the deploy/rollback maintenance helpers (no product or real state touched).
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gallery-maintenance-common.ps1')

$failures = 0
function Check([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output ('PASS ' + $Name) }
  catch { $script:failures++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Expect-Throw([scriptblock]$Body, [string]$Pattern) {
  $threw = $false
  try { & $Body } catch { $threw = $true; if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw ('threw with unexpected message: ' + $_.Exception.Message) } }
  if (-not $threw) { throw 'expected a throw but none happened' }
}

$allowedNode = @(Get-AllowedNodeExecutables)
$nodeExe = 'C:\Users\Toby\AppData\Local\CodexDreamSkin\engine\runtime\node\node.exe'
$helper = 'D:\CodexSkin\helper\gallery-helper.js'

Check 'whitelist has exactly six product files' {
  $allowed = @(Get-AllowedFiles)
  if ($allowed.Count -ne 6) { throw ('expected 6, got ' + $allowed.Count) }
}

Check 'trusted runtime list includes the installed DreamSkin node' {
  if ($allowedNode.Count -lt 1) { throw 'no trusted runtimes' }
  $engine = (Normalize-PathForCompare $nodeExe)
  if (-not ($allowedNode -contains $engine)) { throw ('engine runtime not listed: ' + $engine) }
}

Check 'identity accepts the real helper form' {
  $r = Test-HelperCommandIdentity $nodeExe ('"' + $nodeExe + '" "' + $helper + '"') $helper $allowedNode
  if (-not $r.ok) { throw $r.reason }
}

Check 'identity rejects a script name with a .bak suffix' {
  $r = Test-HelperCommandIdentity $nodeExe ('"' + $nodeExe + '" --log "' + $helper + '.bak"') $helper $allowedNode
  if ($r.ok) { throw 'predicate wrongly accepted a .bak suffix' }
}

Check 'identity rejects a non-node executable' {
  $exe = 'C:\Windows\System32\notepad.exe'
  $r = Test-HelperCommandIdentity $exe ('"' + $exe + '" "' + $helper + '"') $helper $allowedNode
  if ($r.ok) { throw 'predicate wrongly accepted a non-node executable' }
}

Check 'identity rejects an arbitrary file merely named node.exe' {
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('fake-node-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force -Path $tempDir
  $fake = Join-Path $tempDir 'node.exe'
  [IO.File]::WriteAllText($fake, 'not a real runtime', (New-Object Text.UTF8Encoding($false)))
  try {
    $r = Test-HelperCommandIdentity $fake ('"' + $fake + '" "' + $helper + '"') $helper $allowedNode
    if ($r.ok) { throw 'predicate wrongly accepted an arbitrary file named node.exe' }
  } finally { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Check 'identity rejects helper path appearing only as a flag value' {
  $cmd = '"' + $nodeExe + '" --theme-dir "' + $helper + '"'
  $r = Test-HelperCommandIdentity $nodeExe $cmd $helper $allowedNode
  if ($r.ok) { throw 'predicate wrongly accepted the script path as a flag value' }
}

Check 'identity rejects extra second .js script argument' {
  $cmd = '"' + $nodeExe + '" "' + $helper + '" "C:\other\extra.js"'
  $r = Test-HelperCommandIdentity $nodeExe $cmd $helper $allowedNode
  if ($r.ok) { throw 'predicate wrongly accepted two script arguments' }
}

Check 'instance unchanged accepts the same live process' {
  $a = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  $b = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  $r = Test-HelperInstanceUnchanged $a $b 100
  if (-not $r.ok) { throw $r.reason }
}

Check 'instance unchanged rejects a reused pid with a new creation time' {
  $a = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  $b = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 11:30:00' }
  $r = Test-HelperInstanceUnchanged $a $b 100
  if ($r.ok) { throw 'wrongly accepted a pid reused with a different creation time' }
}

Check 'instance unchanged rejects when the listener pid moved' {
  $a = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  $b = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  $r = Test-HelperInstanceUnchanged $a $b 200
  if ($r.ok) { throw 'wrongly accepted a different live listener pid' }
}

Check 'instance unchanged rejects when no live listener owns the port' {
  $a = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  $b = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  foreach ($zero in @(0, $null)) {
    $r = Test-HelperInstanceUnchanged $a $b $zero
    if ($r.ok) { throw ('wrongly accepted a missing/zero listener pid: ' + [string]$zero) }
  }
}

Check 'instance unchanged rejects a changed command line' {
  $a = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = '"' + $nodeExe + '" "' + $helper + '"'; creationDate = '2026-11-10 10:00:00' }
  $b = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = '"' + $nodeExe + '" "C:\other\evil.js"'; creationDate = '2026-11-10 10:00:00' }
  $r = Test-HelperInstanceUnchanged $a $b 100
  if ($r.ok) { throw 'wrongly accepted a changed command line for the same pid' }
}

Check 'instance unchanged rejects incomplete identity fields' {
  $a = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '2026-11-10 10:00:00' }
  $b = [ordered]@{ ok = $true; processId = 100; executable = $nodeExe; commandLine = 'x'; creationDate = '' }
  $r = Test-HelperInstanceUnchanged $a $b 100
  if ($r.ok) { throw 'wrongly accepted an incomplete creation date' }
}

Check 'path within root resolves' {
  $resolved = Assert-UnderRoot 'D:\CodexSkin\helper\engine-worker.ps1' 'D:\CodexSkin' 'target'
  if (-not $resolved.EndsWith('engine-worker.ps1')) { throw 'unexpected resolved path' }
}

Check 'path escaping root is rejected' {
  Expect-Throw { Assert-UnderRoot 'D:\CodexSkin\..\sentinel.txt' 'D:\CodexSkin' 'target' } 'escapes root'
}

Check 'absolute path outside root is rejected' {
  Expect-Throw { Assert-UnderRoot 'D:\Other\sentinel.txt' 'D:\CodexSkin' 'target' } 'escapes root'
}

Check 'sibling prefix path is rejected' {
  Expect-Throw { Assert-UnderRoot 'D:\CodexSkinEvil\launcher.ps1' 'D:\CodexSkin' 'target' } 'escapes root'
}

if ($failures -gt 0) { Write-Output ('FAILURES=' + $failures); exit 1 }
Write-Output 'ALL MAINTENANCE HELPERS PASS'
exit 0
