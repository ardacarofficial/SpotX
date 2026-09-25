# Read-only snapshot of Spotify's top-level windows and taskbar identity.
# Compatible with Windows PowerShell 5.1.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not ('SpotXTaskbarDiagnostics.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SpotXTaskbarDiagnostics {
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey {
        public Guid FormatId;
        public uint PropertyId;
        public PropertyKey(Guid formatId, uint propertyId) {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVariant {
        [FieldOffset(0)] public ushort VariantType;
        [FieldOffset(8)] public IntPtr PointerValue;
        [FieldOffset(8)] public short BooleanValue;
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    public class ShellProperties {
        public int PropertyStoreHResult { get; set; }
        public int AppIdHResult { get; set; }
        public int PreventPinningHResult { get; set; }
        public string AppId { get; set; }
        public bool? PreventPinning { get; set; }
    }

    public static class Native {
        private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);
        private static readonly Guid PropertyStoreId = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        private static readonly Guid AppModelFormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
        private static extern IntPtr GetWindowLongPtr64(IntPtr window, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
        private static extern int GetWindowLong32(IntPtr window, int index);
        [DllImport("dwmapi.dll")]
        private static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out int value, uint size);
        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid interfaceId,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        public static IntPtr[] EnumerateWindows() {
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindowsCallback callback = delegate(IntPtr window, IntPtr parameter) {
                windows.Add(window);
                return true;
            };
            if (!EnumWindows(callback, IntPtr.Zero)) {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            GC.KeepAlive(callback);
            return windows.ToArray();
        }

        public static uint GetStyle(IntPtr window, int index) {
            long value = IntPtr.Size == 8 ? GetWindowLongPtr64(window, index).ToInt64()
                                          : GetWindowLong32(window, index);
            return unchecked((uint)value);
        }

        public static int? GetCloaked(IntPtr window) {
            int value;
            int result = DwmGetWindowAttribute(window, 14, out value, 4);
            return result == 0 ? (int?)value : null;
        }

        private static string ReadString(IPropertyStore store, uint propertyId, out int result) {
            PropertyKey key = new PropertyKey(AppModelFormatId, propertyId);
            PropVariant value;
            result = store.GetValue(ref key, out value);
            if (result != 0) { return null; }
            try {
                if (value.VariantType == 31 && value.PointerValue != IntPtr.Zero)
                    return Marshal.PtrToStringUni(value.PointerValue);
                if (value.VariantType == 8 && value.PointerValue != IntPtr.Zero)
                    return Marshal.PtrToStringBSTR(value.PointerValue);
                return null;
            }
            finally { PropVariantClear(ref value); }
        }

        private static bool? ReadBoolean(IPropertyStore store, uint propertyId, out int result) {
            PropertyKey key = new PropertyKey(AppModelFormatId, propertyId);
            PropVariant value;
            result = store.GetValue(ref key, out value);
            if (result != 0) { return null; }
            try {
                if (value.VariantType == 11) return value.BooleanValue != 0;
                return null;
            }
            finally { PropVariantClear(ref value); }
        }

        public static ShellProperties GetShellProperties(IntPtr window) {
            ShellProperties result = new ShellProperties();
            IPropertyStore store = null;
            Guid iid = PropertyStoreId;
            try {
                result.PropertyStoreHResult = SHGetPropertyStoreForWindow(window, ref iid, out store);
                if (result.PropertyStoreHResult != 0 || store == null) return result;
                int appIdResult;
                int preventPinningResult;
                result.AppId = ReadString(store, 5, out appIdResult);
                result.PreventPinning = ReadBoolean(store, 9, out preventPinningResult);
                result.AppIdHResult = appIdResult;
                result.PreventPinningHResult = preventPinningResult;
                return result;
            }
            catch (COMException exception) {
                result.PropertyStoreHResult = exception.ErrorCode;
                return result;
            }
            finally {
                if (store != null) Marshal.ReleaseComObject(store);
            }
        }
    }
}
'@
}

function Format-WindowHandle {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return $null }
    return ('0x{0:X}' -f $Handle.ToInt64())
}

function Get-WindowRecord {
    param([IntPtr]$Handle, [bool]$IsForeground)
    [uint32]$processId = 0
    $threadId = [SpotXTaskbarDiagnostics.Native]::GetWindowThreadProcessId($Handle, [ref]$processId)
    $owner = [SpotXTaskbarDiagnostics.Native]::GetWindow($Handle, 4)
    $rootOwner = [SpotXTaskbarDiagnostics.Native]::GetAncestor($Handle, 3)
    $shell = [SpotXTaskbarDiagnostics.Native]::GetShellProperties($Handle)
    [pscustomobject]@{
        hwnd = Format-WindowHandle $Handle
        processId = $processId
        threadId = $threadId
        foreground = $IsForeground
        visible = [SpotXTaskbarDiagnostics.Native]::IsWindowVisible($Handle)
        cloaked = [SpotXTaskbarDiagnostics.Native]::GetCloaked($Handle)
        ownerHwnd = Format-WindowHandle $owner
        rootOwnerHwnd = Format-WindowHandle $rootOwner
        style = ('0x{0:X8}' -f [SpotXTaskbarDiagnostics.Native]::GetStyle($Handle, -16))
        exStyle = ('0x{0:X8}' -f [SpotXTaskbarDiagnostics.Native]::GetStyle($Handle, -20))
        appUserModelId = $shell.AppId
        preventPinning = $shell.PreventPinning
        shellPropertyHResults = [pscustomobject]@{
            store = $shell.PropertyStoreHResult
            appId = $shell.AppIdHResult
            preventPinning = $shell.PreventPinningHResult
        }
    }
}

$processes = @(Get-Process -Name Spotify -ErrorAction SilentlyContinue | Sort-Object Id)
$processIds = @{}
$processRecords = foreach ($process in $processes) {
    $processIds[[uint32]$process.Id] = $true
    $path = $null
    $version = $null
    try {
        $path = $process.Path
        if ($path) { $version = (Get-Item -LiteralPath $path).VersionInfo.FileVersion }
    }
    catch { }
    [pscustomobject]@{
        id = $process.Id
        name = $process.ProcessName
        path = $path
        fileVersion = $version
        mainWindowHwnd = Format-WindowHandle $process.MainWindowHandle
    }
}

$foregroundHwnd = [SpotXTaskbarDiagnostics.Native]::GetForegroundWindow()
$foregroundRecord = $null
if ($foregroundHwnd -ne [IntPtr]::Zero) {
    $foregroundRecord = Get-WindowRecord -Handle $foregroundHwnd -IsForeground $true
    $foregroundProcess = Get-Process -Id $foregroundRecord.processId -ErrorAction SilentlyContinue
    $foregroundRecord | Add-Member -NotePropertyName processName -NotePropertyValue $(if ($foregroundProcess) { $foregroundProcess.ProcessName } else { $null })
}

$windows = foreach ($hwnd in [SpotXTaskbarDiagnostics.Native]::EnumerateWindows()) {
    [uint32]$windowProcessId = 0
    $null = [SpotXTaskbarDiagnostics.Native]::GetWindowThreadProcessId($hwnd, [ref]$windowProcessId)
    if ($processIds.ContainsKey($windowProcessId)) {
        Get-WindowRecord -Handle $hwnd -IsForeground ($hwnd -eq $foregroundHwnd)
    }
}

$windowsVersion = [Environment]::OSVersion.Version.ToString()
$windowsBuild = $null
try {
    $osRegistry = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $windowsBuild = ('{0}.{1}' -f $osRegistry.CurrentBuild, $osRegistry.UBR)
}
catch { }

[pscustomobject]@{
    timestamp = [DateTimeOffset]::Now.ToString('o')
    windowsVersion = $windowsVersion
    windowsBuild = $windowsBuild
    processes = @($processRecords)
    foreground = $foregroundRecord
    spotifyWindows = @($windows)
} | ConvertTo-Json -Depth 6
