# Execution-level test of the real launcher window-identity predicate (extracted via AST).
# No window is opened or closed; Get-ProcessChain is stubbed with synthetic data.
# ASCII-only source: Windows PowerShell 5.1 reads BOM-free scripts as ANSI.
$ErrorActionPreference = 'Stop'
$launcher = 'D:\Dirty_work\codex-skin-audit\source\launcher.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'launcher parse errors' }
$names = @('Get-CommandLineOptionValues', 'Normalize-ComparePath', 'Normalize-CompareUrl', 'Normalize-PathIn', 'Test-BrowserExecutable', 'Test-GalleryWindow')
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$text = ($funcs | Where-Object { $names -contains $_.Name } | ForEach-Object { $_.Extent.Text }) -join "`n"
$newTitle = -join ([char[]]@(67, 111, 100, 101, 120, 32, 0x76AE, 0x80A4, 0x5ECA, 32, 183, 32, 68, 114, 101, 97, 109, 83, 107, 105, 110))
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'

$template = @"
`$ProfileDir = 'D:\CodexSkin\data\browser-profile'
function Get-ProcessChain([int]`$ProcessId) { return @(`$global:TestChain) }
$text
`$result = Test-GalleryWindow `$global:TestWindow '$newTitle' 'http://127.0.0.1:9336/'
`$result
"@
$sb = [scriptblock]::Create($template)

$failures = 0
function Check([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output ('PASS ' + $Name) }
  catch { $script:failures++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function New-Window([string]$Title) { return [pscustomobject]@{ ClassName = 'Chrome_WidgetWin_1'; Title = $Title; Pid = 4242 } }
function New-Proc([string]$Exe, [string]$Cmd) { return [pscustomobject]@{ ExecutablePath = $Exe; CommandLine = $Cmd; ProcessId = 4242; ParentProcessId = 1 } }
function Invoke-Predicate($chain, $window) { $global:TestChain = $chain; $global:TestWindow = $window; return (& $sb) }

Check 'accepts exact dedicated profile and exact app url in the window process' {
  $cmd = '"' + $edge + '" --app=http://127.0.0.1:9336/ --user-data-dir="D:\CodexSkin\data\browser-profile"'
  $v = Invoke-Predicate @(New-Proc $edge $cmd) (New-Window $newTitle)
  if (-not $v.ok) { throw ('expected accept, got: ' + $v.reason) }
}

Check 'rejects a different profile with the target as a name prefix' {
  $cmd = '"' + $edge + '" --app=http://127.0.0.1:9336/ --user-data-dir="D:\CodexSkin\data\browser-profile-other"'
  $v = Invoke-Predicate @(New-Proc $edge $cmd) (New-Window $newTitle)
  if ($v.ok) { throw 'wrongly accepted a different profile suffix' }
}

Check 'rejects profile and app url coming from different ancestors' {
  $child = New-Proc $edge ('"' + $edge + '" --app=http://127.0.0.1:9336/')
  $parent = New-Proc $edge ('"' + $edge + '" --user-data-dir="D:\CodexSkin\data\browser-profile"')
  $v = Invoke-Predicate @($child, $parent) (New-Window $newTitle)
  if ($v.ok) { throw 'wrongly accepted a split identity across processes' }
}

Check 'rejects a different app url' {
  $cmd = '"' + $edge + '" --app=http://127.0.0.1:9999/ --user-data-dir="D:\CodexSkin\data\browser-profile"'
  $v = Invoke-Predicate @(New-Proc $edge $cmd) (New-Window $newTitle)
  if ($v.ok) { throw 'wrongly accepted a different app url' }
}

Check 'rejects an untrusted executable' {
  $other = 'C:\Windows\System32\notepad.exe'
  $cmd = '"' + $other + '" --app=http://127.0.0.1:9336/ --user-data-dir="D:\CodexSkin\data\browser-profile"'
  $v = Invoke-Predicate @(New-Proc $other $cmd) (New-Window $newTitle)
  if ($v.ok) { throw 'wrongly accepted an untrusted executable' }
}

Check 'rejects a wrong window title' {
  $cmd = '"' + $edge + '" --app=http://127.0.0.1:9336/ --user-data-dir="D:\CodexSkin\data\browser-profile"'
  $v = Invoke-Predicate @(New-Proc $edge $cmd) (New-Window 'Unrelated documentation - Microsoft Edge')
  if ($v.ok) { throw 'wrongly accepted a mismatched title' }
}

if ($failures -gt 0) { Write-Output ('FAILURES=' + $failures); exit 1 }
Write-Output 'ALL WINDOW-IDENTITY PREDICATE CHECKS PASS'
exit 0
