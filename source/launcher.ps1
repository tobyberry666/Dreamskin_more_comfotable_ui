# ===========================================================================
#  Codex Skin Gallery launcher  -  D:\CodexSkin\launcher.ps1
#
#  Job 1: make sure the local data helper (127.0.0.1:9336) is running.
#  Job 2: show EXACTLY ONE gallery window. If a gallery window already exists
#         it is brought to the foreground instead of opening a second copy.
#
#  This script never starts, restarts or modifies the Codex application.
#  Log: D:\CodexSkin\data\launcher.log
# ===========================================================================

$ErrorActionPreference = 'Stop'

$Root        = 'D:\CodexSkin'
$DataDir     = Join-Path $Root 'data'
$AppDir      = Join-Path $Root 'app'
$HelperDir   = Join-Path $Root 'helper'
$GalleryPage = Join-Path $AppDir 'index.html'
$HelperJs    = Join-Path $HelperDir 'gallery-helper.js'
$HelperLog   = Join-Path $DataDir 'helper.log'
$ProfileDir  = Join-Path $DataDir 'browser-profile'
$LogPath     = Join-Path $DataDir 'launcher.log'
$HelperPort  = 9336
$MutexName   = 'Local\CodexSkinGalleryLauncher'
$WindowWaitSeconds = 25
# Windows PowerShell 5.1 reads BOM-free scripts as ANSI, so build the Chinese
# page-title markers and the app URL from code points instead of literals.
$GalleryTitleMarker = -join ([char[]]@(0x76AE, 0x80A4, 0x5ECA))
$NewWindowTitle = -join ([char[]]@(67, 111, 100, 101, 120, 32, 0x76AE, 0x80A4, 0x5ECA, 32, 183, 32, 68, 114, 101, 97, 109, 83, 107, 105, 110))
$LegacyWindowTitle = -join ([char[]]@(25105, 30340, 32, 67, 111, 100, 101, 120, 32, 30382, 32932, 32, 183, 32, 68, 114, 101, 97, 109, 83, 107, 105, 110))
$AppUrl = 'http://127.0.0.1:' + $HelperPort + '/'
$LegacyUrl = ([uri](Join-Path $AppDir 'index.html')).AbsoluteUri

function Write-Log {
  param([string]$Message)
  try {
    if (-not (Test-Path -LiteralPath $DataDir)) { return }
    if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 512000)) {
      Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    }
    $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
}

# ---------------------------------------------------------------------------
#  native window helpers
# ---------------------------------------------------------------------------
if (-not ('CodexSkin.Win32' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CodexSkin
{
    public class WinInfo
    {
        public IntPtr Hwnd;
        public int Pid;
        public string Title;
        public string ClassName;
        public bool Iconic;
    }

    public static class Win32
    {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int command);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        public const uint WM_CLOSE = 0x0010;
        public const int SW_RESTORE = 9;

        public static List<WinInfo> GetWindows()
        {
            List<WinInfo> list = new List<WinInfo>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd)) { return true; }
                StringBuilder title = new StringBuilder(512);
                GetWindowTextW(hWnd, title, 512);
                StringBuilder cls = new StringBuilder(256);
                GetClassNameW(hWnd, cls, 256);
                uint pid;
                GetWindowThreadProcessId(hWnd, out pid);
                WinInfo info = new WinInfo();
                info.Hwnd = hWnd;
                info.Pid = (int)pid;
                info.Title = title.ToString();
                info.ClassName = cls.ToString();
                info.Iconic = IsIconic(hWnd);
                list.Add(info);
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
'@
}

function Get-ProcessInfo([int]$ProcessId) {
  try { return Get-CimInstance Win32_Process -Filter ('ProcessId=' + $ProcessId) -ErrorAction Stop }
  catch { return $null }
}

function Get-ProcessChain([int]$ProcessId) {
  $chain = @()
  $current = $ProcessId
  $guard = 0
  while ($current -and $current -ne 0 -and $guard -lt 12) {
    $info = Get-ProcessInfo $current
    if ($null -eq $info) { break }
    $chain += $info
    $current = [int]$info.ParentProcessId
    $guard++
  }
  return $chain
}

function Get-CommandLineOptionValues([string]$CommandLine, [string]$Name) {
  # Collect values for --Name=value and --Name value forms, so matching is exact not substring.
  $values = @()
  if (-not $CommandLine) { return $values }
  $tokens = @()
  foreach ($m in [regex]::Matches($CommandLine, '"([^"]*)"|(\S+)')) {
    if ($m.Groups[1].Success) { $tokens += $m.Groups[1].Value } else { $tokens += $m.Groups[2].Value }
  }
  for ($i = 0; $i -lt $tokens.Count; $i++) {
    $token = $tokens[$i]
    if ($token -match ('^(?i)' + [regex]::Escape('--' + $Name) + '=(.*)$')) {
      $value = $Matches[1]
      if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) { $value = $value.Substring(1, $value.Length - 2) }
      $values += $value
      continue
    }
    if ($token -ieq ('--' + $Name) -and ($i + 1) -lt $tokens.Count) {
      $value = $tokens[$i + 1]
      if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) { $value = $value.Substring(1, $value.Length - 2) }
      $values += $value
    }
  }
  return $values
}

function Normalize-ComparePath([string]$Path) {
  if (-not $Path) { return $null }
  try { return ([IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [char]'/', [char]'\')) }
  catch { return $Path.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [char]'/', [char]'\')) }
}

function Normalize-CompareUrl([string]$Value) {
  if (-not $Value) { return $null }
  try { return ([uri]$Value).AbsoluteUri.TrimEnd([char]'/') } catch { return $Value.TrimEnd([char]'/') }
}

function Test-BrowserExecutable([string]$ExecutablePath) {
  if (-not $ExecutablePath) { return $false }
  $name = [IO.Path]::GetFileName($ExecutablePath).ToLowerInvariant()
  if (-not (@('msedge.exe', 'chrome.exe') -contains $name)) { return $false }
  $roots = @([Environment]::GetEnvironmentVariable('ProgramFiles(x86)'), [Environment]::GetEnvironmentVariable('ProgramFiles'), $env:LOCALAPPDATA)
  foreach ($root in $roots) {
    if ($root -and $ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Test-GalleryWindow {
  # A window is trusted only when its exact title matches AND the window's own browser
  # process proves the exact dedicated profile AND the exact app URL in the same command line.
  param($Window, [string]$ExpectedTitle, [string]$UrlNeedle)
  if ($null -eq $Window) { return @{ ok = $false; reason = 'no window' } }
  if ([string]$Window.ClassName -ne 'Chrome_WidgetWin_1') { return @{ ok = $false; reason = 'not a browser window class' } }
  if (([string]$Window.Title).Trim() -cne $ExpectedTitle) { return @{ ok = $false; reason = 'title does not match exactly' } }
  $chain = @(Get-ProcessChain ([int]$Window.Pid))
  if ($chain.Count -eq 0) { return @{ ok = $false; reason = 'window process not found' } }
  $executable = [string]$chain[0].ExecutablePath
  if (-not (Test-BrowserExecutable $executable)) { return @{ ok = $false; reason = ('not a trusted browser executable: ' + $executable) } }
  $expectedProfile = Normalize-ComparePath $ProfileDir
  $expectedUrl = Normalize-CompareUrl $UrlNeedle
  # Require ONE process (the window's own process) to carry BOTH exact tokens; this
  # rejects different-profile prefixes and profile/URL coming from different ancestors.
  $owner = $chain[0]
  $profileValues = @(Get-CommandLineOptionValues ([string]$owner.CommandLine) 'user-data-dir')
  $appValues = @(Get-CommandLineOptionValues ([string]$owner.CommandLine) 'app')
  if (-not (Normalize-PathIn @($profileValues) $expectedProfile)) {
    return @{ ok = $false; reason = 'dedicated profile not proven exactly by the window process' }
  }
  if (-not (Normalize-PathIn @($appValues) $expectedUrl)) {
    return @{ ok = $false; reason = 'expected app url not proven exactly by the window process' }
  }
  return @{ ok = $true; reason = 'verified'; executable = $executable }
}

function Normalize-PathIn([string[]]$Values, [string]$Expected) {
  if (-not $Expected) { return $false }
  foreach ($value in @($Values)) {
    if (-not $value) { continue }
    $normalized = $null
    if ($Expected -match '^[a-zA-Z]+://') { $normalized = Normalize-CompareUrl $value } else { $normalized = Normalize-ComparePath $value }
    if ($normalized -and ($normalized -ieq $Expected)) { return $true }
  }
  return $false
}

function Get-GalleryWindows {
  $result = @()
  foreach ($window in @([CodexSkin.Win32]::GetWindows())) {
    $verdict = Test-GalleryWindow $window $NewWindowTitle $AppUrl
    if ($verdict.ok) { $result += $window }
  }
  return $result
}

function Get-LegacyGalleryWindows {
  $result = @()
  foreach ($window in @([CodexSkin.Win32]::GetWindows())) {
    $verdict = Test-GalleryWindow $window $LegacyWindowTitle $LegacyUrl
    if ($verdict.ok) { $result += $window }
  }
  return $result
}

function Show-AppWindow {
  param($Window)
  try { if ($Window.Iconic) { [void][CodexSkin.Win32]::ShowWindow($Window.Hwnd, [CodexSkin.Win32]::SW_RESTORE) } } catch { }
  try { [void][CodexSkin.Win32]::SetForegroundWindow($Window.Hwnd) } catch { }
  try {
    $shell = New-Object -ComObject WScript.Shell
    [void]$shell.AppActivate([int]$Window.Pid)
  } catch { }
}

function Close-AppWindow {
  param($Window)
  try { [void][CodexSkin.Win32]::PostMessage($Window.Hwnd, [CodexSkin.Win32]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) } catch { }
}

function Test-HelperHealth {
  try {
    $response = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $HelperPort + '/api/health') -UseBasicParsing -TimeoutSec 3
    $health = $response.Content | ConvertFrom-Json
    return ($response.StatusCode -eq 200 -and $health.version -eq 2)
  } catch { return $false }
}

function Resolve-NodePath {
  $systemNode = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($systemNode) { return $systemNode.Source }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\CodexDreamSkin\payload\runtime\node\node.exe'),
    (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\engine\runtime\node\node.exe')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
  }
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  return $null
}

function Resolve-BrowserPath {
  $roots = @()
  $roots += [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  $roots += [Environment]::GetEnvironmentVariable('ProgramFiles')
  $roots += $env:LOCALAPPDATA
  $relative = @(
    'Microsoft\Edge\Application\msedge.exe',
    'Google\Chrome\Application\chrome.exe'
  )
  foreach ($root in $roots) {
    if (-not $root) { continue }
    foreach ($item in $relative) {
      $candidate = Join-Path $root $item
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }
  return $null
}

function ConvertTo-QuotedArguments {
  param([string[]]$Items)
  $quoted = @()
  foreach ($item in $Items) { $quoted += ('"' + $item + '"') }
  return $quoted
}

# ---------------------------------------------------------------------------
#  single instance guard
# ---------------------------------------------------------------------------
$haveMutex = $false
$mutex = $null
try {
  $mutex = New-Object System.Threading.Mutex($false, $MutexName)
  try { $haveMutex = $mutex.WaitOne(30000, $false) }
  catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
} catch {
  $haveMutex = $true
}
if (-not $haveMutex) {
  Write-Log 'another gallery launcher is still working; nothing to do'
  exit 0
}

try {
  if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }

  . (Join-Path $Root 'helper\tray-bootstrap.ps1')
  Ensure-DreamSkinTray

  # ---- 1. local data helper -------------------------------------------
  if (-not (Test-HelperHealth)) {
    $node = Resolve-NodePath
    if ($node -and (Test-Path -LiteralPath $HelperJs -PathType Leaf)) {
      try {
        Start-Process -FilePath $node -ArgumentList ('"' + $HelperJs + '"') -WindowStyle Hidden -RedirectStandardOutput $HelperLog -RedirectStandardError ($HelperLog + '.err')
        for ($i = 0; $i -lt 20; $i++) {
          Start-Sleep -Milliseconds 400
          if (Test-HelperHealth) { break }
        }
        Write-Log ('helper started healthy=' + (Test-HelperHealth))
      } catch {
        Write-Log ('helper start failed: ' + $_.Exception.Message)
      }
    } else {
      Write-Log 'helper could not start: node executable or helper script not found'
    }
  }

  if (-not (Test-HelperHealth)) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show('The local gallery service could not start. Please reopen Codex Skin Gallery. See data/helper.log.err for details.', 'Codex Skin Gallery')
    exit 1
  }

  # ---- 1. retire the legacy file:// page ------------------------------
  $legacy = @(Get-LegacyGalleryWindows)
  if ($legacy.Count -gt 0) {
    foreach ($window in $legacy) { Close-AppWindow -Window $window }
    Write-Log ('closed legacy file page windows=' + $legacy.Count)
    Start-Sleep -Milliseconds 800
  }

  # ---- 2. one gallery window at a time --------------------------------
  $existing = @(Get-GalleryWindows)
  if ($existing.Count -gt 0) {
    $ordered = @($existing | Where-Object { -not $_.Iconic }) + @($existing | Where-Object { $_.Iconic })
    $primary = @($ordered | Select-Object -First 1)[0]
    if ($null -ne $primary) {
      Show-AppWindow -Window $primary
      $closed = 0
      foreach ($window in $existing) {
        if ([int64]$window.Hwnd -eq [int64]$primary.Hwnd) { continue }
        Close-AppWindow -Window $window
        $closed++
      }
      Write-Log ('activated existing gallery window pid=' + $primary.Pid + ' closed_duplicates=' + $closed)
      exit 0
    }
  }

  # ---- 3. page must exist ---------------------------------------------
  if (-not (Test-Path -LiteralPath $GalleryPage -PathType Leaf)) {
    Write-Log ('gallery page missing: ' + $GalleryPage)
    exit 1
  }

  $browser = Resolve-BrowserPath
  if (-not $browser) {
    Write-Log 'no Edge/Chrome found; refusing to open an unmanaged default-browser window'
    exit 1
  }

  if (-not (Test-Path -LiteralPath $ProfileDir)) { New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null }
  $pageUrl = 'http://127.0.0.1:' + $HelperPort + '/'

  # ---- 4. open the app window in the dedicated profile -----------------
  $launchArgs = @(
    ('--app=' + $pageUrl),
    '--window-size=1380,960',
    ('--user-data-dir=' + $ProfileDir),
    '--no-first-run',
    '--no-default-browser-check'
  )
  try {
    Start-Process -FilePath $browser -ArgumentList (ConvertTo-QuotedArguments -Items $launchArgs)
    Write-Log ('launch app window using ' + $browser)
  } catch {
    Write-Log ('launch failed: ' + $_.Exception.Message)
  }

  $deadline = (Get-Date).AddSeconds($WindowWaitSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (@(Get-GalleryWindows).Count -gt 0) {
      Write-Log 'gallery window is up'
      exit 0
    }
  }

  # ---- 5. no unmanaged fallback: a default-profile window could not be verified ----
  Write-Log 'dedicated-profile gallery window did not appear; refusing to open an unmanaged fallback window'
  exit 1
}
finally {
  if ($haveMutex -and $mutex) { try { $mutex.ReleaseMutex() } catch { } }
  if ($mutex) { try { $mutex.Dispose() } catch { } }
}
