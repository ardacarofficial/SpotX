# Experimental exact-build, session-only native guard. Restart Spotify to undo.
[CmdletBinding(SupportsShouldProcess=$true)]
param([switch]$Undo, [string]$StatePath)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw '64-bit PowerShell is required.' }
$exe = Join-Path $env:APPDATA 'Spotify\Spotify.exe'
$cefPath = Join-Path $env:APPDATA 'Spotify\libcef.dll'
$targets = @(Get-Process Spotify -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -and $_.MainWindowHandle -ne [IntPtr]::Zero })
if ($targets.Count -ne 1) { throw 'Expected one exact Spotify main window.' }
$target = $targets[0]
Add-Type -Path (Join-Path $PSScriptRoot 'SpotifyFrameGuard.Native.cs')
[uint32]$owner = 0
$threadId = [SpotifyFrameGuardNative]::GetWindowThreadProcessId($target.MainWindowHandle, [ref]$owner)
if ($owner -ne $target.Id) { throw 'Window changed.' }
$expectedHash = 'EB2F59B8997949875C4829A5DC0448600BABA3B9F24F8FD0B45A1DC9388AAF73'
$sha = [Security.Cryptography.SHA256]::Create()
$stream = [IO.File]::OpenRead($cefPath)
try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
finally { $stream.Dispose(); $sha.Dispose() }
if ($actualHash -ne $expectedHash) { throw 'Unsupported CEF file hash; refusing native modification.' }
$cef = @($target.Modules | Where-Object FileName -eq $cefPath)
if ($cef.Count -ne 1) { throw 'The verified CEF module is not loaded.' }
if ($Undo) {
    if (-not $StatePath) { throw 'Undo requires the state file printed by Apply.' }
    $saved = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($saved.ProcessId -ne $target.Id -or $saved.ThreadId -ne $threadId) { throw 'The saved Spotify process/window is no longer current; no write performed.' }
    if ($PSCmdlet.ShouldProcess('Spotify main window', 'Remove experimental session guard')) {
        [SpotifyFrameGuardNative]::Undo($saved.ProcessId,$saved.ThreadId,$saved.ProcessStartTicks,$saved.Site,$saved.Page,$saved.OriginalHex,$saved.PatchedHex,$cef[0].BaseAddress.ToInt64())
        'Guard removed. Its inert allocation will be released when Spotify exits.'
    }
    return
}
function Get-RemoteExport([string]$ModuleName,[string]$ExportName) {
    $local = [SpotifyFrameGuardNative]::GetModuleHandle($ModuleName)
    $address = [SpotifyFrameGuardNative]::GetProcAddress($local,$ExportName)
    $remote = @($target.Modules | Where-Object ModuleName -ieq $ModuleName)
    if ($local -eq [IntPtr]::Zero -or $address -eq [IntPtr]::Zero -or $remote.Count -ne 1) { throw ('Cannot resolve ' + $ExportName) }
    $localModule = @([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object ModuleName -ieq $ModuleName)
    if ($localModule.Count -ne 1 -or $address.ToInt64() -lt $local.ToInt64() -or
        $address.ToInt64() -ge ($local.ToInt64() + $localModule[0].ModuleMemorySize) -or
        $localModule[0].ModuleMemorySize -ne $remote[0].ModuleMemorySize -or
        $localModule[0].FileName -ine $remote[0].FileName) { throw ('Export module mismatch: ' + $ExportName) }
    return $remote[0].BaseAddress.ToInt64() + $address.ToInt64() - $local.ToInt64()
}
$isIconic = Get-RemoteExport 'user32.dll' 'IsIconic'
$register = Get-RemoteExport 'ntdll.dll' 'RtlAddFunctionTable'
if (-not $StatePath) { $StatePath = Join-Path $env:TEMP ('spotify-frame-guard-{0}-{1}.json' -f $target.Id,[Guid]::NewGuid().ToString('N')) }
if (Test-Path -LiteralPath $StatePath) { throw 'State file already exists.' }
if ($PSCmdlet.ShouldProcess(('Spotify PID {0}' -f $target.Id), 'Apply exact-build session-only minimized-frame guard')) {
    Write-Host ('Recovery state (written before code exchange): ' + $StatePath)
    $state = [SpotifyFrameGuardNative]::Apply($target.Id,$threadId,$target.MainWindowHandle.ToInt64(),$cef[0].BaseAddress.ToInt64(),$isIconic,$register,[IO.Path]::GetFullPath($StatePath))
    [pscustomobject]@{Status='ExperimentalGuardApplied'; ProcessId=$target.Id; ThreadId=$threadId; StatePath=$StatePath; Persistent=$false} | ConvertTo-Json
}
