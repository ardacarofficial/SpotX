# Refreshes only the installed Spotify main window's taskbar registration.
# This is a targeted shell repair attempt, not proof that the visual issue is fixed.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'

if (-not ('SpotXTaskbarRepair.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SpotXTaskbarRepair {
    [ComImport]
    [Guid("56FDF342-FD6D-11D0-958A-006097C9A090")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList {
        [PreserveSig] int HrInit();
        [PreserveSig] int AddTab(IntPtr window);
        [PreserveSig] int DeleteTab(IntPtr window);
        [PreserveSig] int ActivateTab(IntPtr window);
        [PreserveSig] int SetActiveAlt(IntPtr window);
    }

    [ComImport]
    [Guid("56FDF344-FD6D-11D0-958A-006097C9A090")]
    public class TaskbarListObject { }

    // Keep the IUnknown-only COM interface inside managed code. PowerShell 5.1
    // cannot reliably cast its System.__ComObject wrapper to this interface.
    public sealed class TaskbarSession : IDisposable {
        private ITaskbarList taskbar = (ITaskbarList)new TaskbarListObject();
        public int HrInit() { return taskbar.HrInit(); }
        public int AddTab(IntPtr window) { return taskbar.AddTab(window); }
        public int DeleteTab(IntPtr window) { return taskbar.DeleteTab(window); }
        public int ActivateTab(IntPtr window) { return taskbar.ActivateTab(window); }
        public void Dispose() {
            if (taskbar != null) {
                Marshal.ReleaseComObject(taskbar);
                taskbar = null;
            }
        }
    }

    public static class Native {
        private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        public static IntPtr[] EnumerateWindows() {
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindowsCallback callback = delegate(IntPtr window, IntPtr parameter) {
                windows.Add(window);
                return true;
            };
            if (!EnumWindows(callback, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            GC.KeepAlive(callback);
            return windows.ToArray();
        }
    }
}
'@
}

$installedExe = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'Spotify\Spotify.exe'))
$comparison = [StringComparison]::OrdinalIgnoreCase
$result = [ordered]@{
    timestamp = [DateTimeOffset]::Now.ToString('o')
    status = 'NotAttempted'
    exe = $installedExe
    processId = $null
    hwnd = $null
    wasForeground = $false
    hrInit = $null
    deleteTab = $null
    addTab = $null
    activateTab = $null
    recoveryAddTab = $null
    error = $null
}

function Test-MainSpotifyWindow {
    param([IntPtr]$Window, [uint32]$ExpectedPid)
    if (-not [SpotXTaskbarRepair.Native]::IsWindow($Window)) { return $false }
    if (-not [SpotXTaskbarRepair.Native]::IsWindowVisible($Window)) { return $false }
    if ([SpotXTaskbarRepair.Native]::GetWindow($Window, 4) -ne [IntPtr]::Zero) { return $false }
    if ([SpotXTaskbarRepair.Native]::GetAncestor($Window, 2) -ne $Window) { return $false }
    if ([SpotXTaskbarRepair.Native]::GetAncestor($Window, 3) -ne $Window) { return $false }
    [uint32]$actualPid = 0
    $null = [SpotXTaskbarRepair.Native]::GetWindowThreadProcessId($Window, [ref]$actualPid)
    if ($actualPid -ne $ExpectedPid) { return $false }
    $process = Get-Process -Id $actualPid -ErrorAction SilentlyContinue
    if (-not $process -or $process.ProcessName -ne 'Spotify') { return $false }
    try {
        if (-not [string]::Equals([IO.Path]::GetFullPath($process.Path), $installedExe, $comparison)) { return $false }
        return $process.MainWindowHandle -eq $Window
    }
    catch { return $false }
}

$taskbar = $null
$deleteAttempted = $false
$addSucceeded = $false
$failed = $false
try {
    if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
        throw 'Installed Spotify.exe was not found.'
    }

    $candidates = @()
    foreach ($window in [SpotXTaskbarRepair.Native]::EnumerateWindows()) {
        [uint32]$windowProcessId = 0
        $null = [SpotXTaskbarRepair.Native]::GetWindowThreadProcessId($window, [ref]$windowProcessId)
        if ($windowProcessId -ne 0 -and (Test-MainSpotifyWindow -Window $window -ExpectedPid $windowProcessId)) {
            $candidates += [pscustomobject]@{ Hwnd = $window; Pid = $windowProcessId }
        }
    }
    if ($candidates.Count -ne 1) {
        throw ('Expected exactly one visible Spotify main window; found {0}.' -f $candidates.Count)
    }

    $target = $candidates[0]
    $result.processId = $target.Pid
    $result.hwnd = ('0x{0:X}' -f $target.Hwnd.ToInt64())
    if (-not $PSCmdlet.ShouldProcess($result.hwnd, 'Refresh Spotify taskbar registration with DeleteTab/AddTab')) {
        $result.status = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
    }
    else {
        if (-not (Test-MainSpotifyWindow -Window $target.Hwnd -ExpectedPid $target.Pid)) {
            throw 'Spotify main window changed before the repair.'
        }
        $result.wasForeground = [SpotXTaskbarRepair.Native]::GetForegroundWindow() -eq $target.Hwnd
        $taskbar = New-Object SpotXTaskbarRepair.TaskbarSession
        $result.hrInit = $taskbar.HrInit()
        if ($result.hrInit -ne 0) { throw ('ITaskbarList.HrInit failed: {0}' -f $result.hrInit) }

        if (-not (Test-MainSpotifyWindow -Window $target.Hwnd -ExpectedPid $target.Pid)) {
            throw 'Spotify main window changed before DeleteTab.'
        }
        $deleteAttempted = $true
        $result.deleteTab = $taskbar.DeleteTab($target.Hwnd)
        if ($result.deleteTab -ne 0) { throw ('ITaskbarList.DeleteTab failed: {0}' -f $result.deleteTab) }

        if (-not (Test-MainSpotifyWindow -Window $target.Hwnd -ExpectedPid $target.Pid)) {
            throw 'Spotify main window changed after DeleteTab.'
        }
        $result.addTab = $taskbar.AddTab($target.Hwnd)
        if ($result.addTab -ne 0) { throw ('ITaskbarList.AddTab failed: {0}' -f $result.addTab) }
        $addSucceeded = $true

        if ($result.wasForeground -and
            [SpotXTaskbarRepair.Native]::GetForegroundWindow() -eq $target.Hwnd) {
            $result.activateTab = $taskbar.ActivateTab($target.Hwnd)
            if ($result.activateTab -ne 0) {
                throw ('ITaskbarList.ActivateTab failed: {0}' -f $result.activateTab)
            }
        }
        $result.status = 'Refreshed'
    }
}
catch {
    $failed = $true
    $result.status = 'Failed'
    $result.error = $_.Exception.Message
}
finally {
    if ($deleteAttempted -and -not $addSucceeded -and $null -ne $taskbar) {
        try {
            if (Test-MainSpotifyWindow -Window $target.Hwnd -ExpectedPid $target.Pid) {
                $result.recoveryAddTab = $taskbar.AddTab($target.Hwnd)
            }
            else {
                $result.error += ' Recovery skipped because the Spotify window changed.'
            }
        }
        catch { $result.error += (' Recovery AddTab threw: {0}' -f $_.Exception.Message) }
    }
    if ($null -ne $taskbar) {
        $taskbar.Dispose()
    }
}

[pscustomobject]$result | ConvertTo-Json -Depth 4
if ($failed) { exit 1 }
