# Both desktop launchers call this before any early return.
function Ensure-DreamSkinTray {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $name = "Local\CodexDreamSkin.$sid.Tray"
  $ready = $false
  $probe = $null
  try {
    $probe = [System.Threading.Mutex]::OpenExisting($name)
    try { $free = $probe.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $free = $true }
    if ($free) { $probe.ReleaseMutex() } else { $ready = $true }
  } catch { } finally { if ($probe) { $probe.Dispose() } }
  if ($ready) { return }
  $scriptPath = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\engine\scripts\tray-dream-skin.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath)) { Write-Log 'Dream Skin tray script is missing'; return }
  $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $child = Start-Process -FilePath $exe -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $scriptPath + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $DataDir 'tray.log') -RedirectStandardError (Join-Path $DataDir 'tray-error.log')
  # Tray initialization takes the engine operation lock briefly; let it finish first.
  Start-Sleep -Seconds 2
  if ($child.HasExited) { Write-Log ('Dream Skin tray exited: ' + $child.ExitCode) }
  else { Write-Log ('Dream Skin tray started pid=' + $child.Id) }
}
