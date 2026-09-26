// Per-user compiled host. Spotify binaries on disk are never modified.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using System.Web.Script.Serialization;

public static class SpotifyWindowHelper {
    const string CefHash = "EB2F59B8997949875C4829A5DC0448600BABA3B9F24F8FD0B45A1DC9388AAF73";
    static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpotXMinimizeGuard");
    static readonly string Spotify = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Spotify", "Spotify.exe");
    static readonly string MutexScope = CreateMutexScope();
    static readonly Dictionary<string, int> Attempts = new Dictionary<string, int>();
    static readonly Dictionary<string, long> Finished = new Dictionary<string, long>();
    static readonly HashSet<string> WindowSkips = new HashSet<string>();
    static readonly HashSet<string> Taskbars = new HashSet<string>();
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr at, byte[] data, UIntPtr length, out UIntPtr read);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint command);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [ComImport, Guid("56FDF342-FD6D-11D0-958A-006097C9A090"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITaskbarList {
        [PreserveSig] int HrInit(); [PreserveSig] int AddTab(IntPtr h);
        [PreserveSig] int DeleteTab(IntPtr h); [PreserveSig] int ActivateTab(IntPtr h);
        [PreserveSig] int SetActiveAlt(IntPtr h);
    }
    [ComImport, Guid("56FDF344-FD6D-11D0-958A-006097C9A090")]
    class TaskbarObject { }
    static void Log(string message) {
        try {
            string path = Path.Combine(Folder, "helper.log");
            if (File.Exists(path) && new FileInfo(path).Length > 1048576) {
                File.Copy(path, path + ".old", true); File.WriteAllText(path, "");
            }
            File.AppendAllText(path, DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine);
        } catch { /* A log failure must not terminate automatic application. */ }
    }
    static bool Same(string a, string b) { return String.Equals(a,b,StringComparison.OrdinalIgnoreCase); }
    static bool StopRequested() { return File.Exists(Path.Combine(Folder,"helper.stop")); }
    static string CreateMutexScope() {
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            return "Local\\SpotXCompiledWindowHelper." + identity.User.Value + ".";
    }
    static string MutexName(string role) { return MutexScope + role; }
    static bool Own(Mutex mutex) {
        try { return mutex.WaitOne(0); }
        catch (AbandonedMutexException) { return true; }
    }
    static bool WorkerRunning() {
        using (Mutex mutex = new Mutex(false,MutexName("Worker"))) {
            bool owned = Own(mutex);
            if (owned) mutex.ReleaseMutex();
            return !owned;
        }
    }
    static bool WindowMatches(Process p, IntPtr h) {
        uint owner;
        return h != IntPtr.Zero && SpotifyFrameGuardNative.GetWindowThreadProcessId(h, out owner) != 0 &&
            owner == p.Id && p.MainWindowHandle == h && IsWindowVisible(h) &&
            GetWindow(h,4) == IntPtr.Zero && GetAncestor(h,2) == h && GetAncestor(h,3) == h;
    }
    static ProcessModule Module(Process p, string name) {
        foreach (ProcessModule module in p.Modules) if (Same(module.ModuleName,name)) return module;
        throw new InvalidOperationException("Module not ready: " + name);
    }
    static long Export(Process p, string moduleName, string exportName) {
        IntPtr local = SpotifyFrameGuardNative.GetModuleHandle(moduleName);
        IntPtr address = SpotifyFrameGuardNative.GetProcAddress(local,exportName);
        using (Process self = Process.GetCurrentProcess()) {
            ProcessModule own = Module(self,moduleName), remote = Module(p,moduleName);
            long offset = address.ToInt64() - local.ToInt64();
            if (local == IntPtr.Zero || address == IntPtr.Zero || offset < 0 || offset >= own.ModuleMemorySize ||
                own.ModuleMemorySize != remote.ModuleMemorySize || !Same(own.FileName,remote.FileName))
                throw new InvalidOperationException("Export module mismatch: " + exportName);
            return remote.BaseAddress.ToInt64() + offset;
        }
    }
    static byte[] Read(IntPtr process, long at, int length) {
        byte[] bytes = new byte[length]; UIntPtr read;
        if (!ReadProcessMemory(process,new IntPtr(at),bytes,(UIntPtr)length,out read) || read.ToUInt64() != (ulong)length)
            throw new InvalidOperationException("Guard verification read failed.");
        return bytes;
    }
    static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", ""); }
    static bool Verify(Process p, IntPtr hwnd, long moduleBase, string statePath, long iconic) {
        SpotifyFrameGuardState s = new JavaScriptSerializer().Deserialize<SpotifyFrameGuardState>(File.ReadAllText(statePath));
        if (s.ProcessId != p.Id || s.ProcessStartTicks != p.StartTime.ToUniversalTime().Ticks || s.Site != moduleBase + 0x1D1312B)
            return false;
        long delta = s.Page - s.Site - 9;
        if (delta < Int32.MinValue || delta > Int32.MaxValue || (s.Page & 0xFFFF) != 0) return false;
        string expected = "4889F190E8" + Hex(BitConverter.GetBytes((int)delta));
        if (!Same(s.PatchedHex,expected) || !Same(s.OriginalHex,"488B4E60E83CF75800")) return false;
        IntPtr handle = OpenProcess(0x10,false,p.Id);
        if (handle == IntPtr.Zero) throw new InvalidOperationException("Read-only verification open failed.");
        try {
            byte[] wrapper = SpotifyFrameGuardNative.BuildWrapper(hwnd.ToInt64(),iconic);
            return Same(Hex(Read(handle,s.Site,9)),expected) && Same(Hex(Read(handle,s.Page,wrapper.Length)),Hex(wrapper));
        } finally { CloseHandle(handle); }
    }
    static void RepairTaskbar(Process p, IntPtr hwnd) {
        ITaskbarList taskbar = null; bool deleted = false, added = false;
        try {
            if (!WindowMatches(p,hwnd)) throw new InvalidOperationException("Window changed before taskbar repair.");
            taskbar = (ITaskbarList)new TaskbarObject(); Marshal.ThrowExceptionForHR(taskbar.HrInit());
            deleted = true; Marshal.ThrowExceptionForHR(taskbar.DeleteTab(hwnd));
            if (!WindowMatches(p,hwnd)) throw new InvalidOperationException("Window changed during taskbar repair.");
            Marshal.ThrowExceptionForHR(taskbar.AddTab(hwnd)); added = true;
            if (GetForegroundWindow() == hwnd) Marshal.ThrowExceptionForHR(taskbar.ActivateTab(hwnd));
        } finally {
            if (taskbar != null) {
                try { if (deleted && !added && WindowMatches(p,hwnd)) Marshal.ThrowExceptionForHR(taskbar.AddTab(hwnd)); }
                finally { Marshal.ReleaseComObject(taskbar); }
            }
        }
    }
    static void Handle(Process p, bool checkOnly) {
        if (!Same(p.MainModule.FileName,Spotify)) return;
        IntPtr hwnd = p.MainWindowHandle;
        if (!WindowMatches(p,hwnd) || (DateTime.UtcNow-p.StartTime.ToUniversalTime()).TotalSeconds < 5) return;
        string key = p.Id + "-" + p.StartTime.ToUniversalTime().Ticks;
        string windowKey = key + "-" + hwnd.ToInt64();
        if (!checkOnly && !Taskbars.Contains(windowKey)) {
            Taskbars.Add(windowKey);
            try { RepairTaskbar(p,hwnd); Log("Taskbar refreshed " + windowKey); }
            catch (Exception e) { Log("Taskbar repair failed " + windowKey + ": " + e.Message); }
        }
        long finishedWindow;
        if (!checkOnly && Finished.TryGetValue(key,out finishedWindow)) {
            if (finishedWindow != hwnd.ToInt64() && WindowSkips.Add(windowKey))
                Log("Main HWND changed in the same process; automatic frame-guard retries are skipped. Restart Spotify: " + windowKey);
            return;
        }
        int attempt; Attempts.TryGetValue(key,out attempt);
        if (!checkOnly && attempt >= 3) return;
        Attempts[key] = attempt + 1;
        try {
            ProcessModule cef = Module(p,"libcef.dll");
            if (!Same(cef.FileName,Path.Combine(Path.GetDirectoryName(Spotify),"libcef.dll"))) throw new InvalidOperationException("CEF path mismatch.");
            string hash;
            using (var sha = SHA256.Create()) using (var stream = File.OpenRead(cef.FileName)) hash = Hex(sha.ComputeHash(stream));
            if (!Same(hash,CefHash)) { Finished[key] = hwnd.ToInt64(); Log("Unsupported CEF; skipped " + key); return; }
            long iconic = Export(p,"user32.dll","IsIconic");
            string state = Path.Combine(Folder,"state-" + key + ".json");
            if (File.Exists(state)) {
                bool active = Verify(p,hwnd,cef.BaseAddress.ToInt64(),state,iconic);
                Finished[key] = hwnd.ToInt64();
                Log((active ? "Verified active " : "Recovery state exists but guard is not verified; restart Spotify: ") + windowKey);
                return;
            }
            if (checkOnly) { Log("No guard state for " + key); return; }
            long register = Export(p,"ntdll.dll","RtlAddFunctionTable");
            uint owner; uint tid = SpotifyFrameGuardNative.GetWindowThreadProcessId(hwnd,out owner);
            if (owner != p.Id || !WindowMatches(p,hwnd)) throw new InvalidOperationException("Window changed before apply.");
            // After entering native Apply never retry this process automatically.
            Finished[key] = hwnd.ToInt64();
            SpotifyFrameGuardNative.Apply(p.Id,(int)tid,hwnd.ToInt64(),cef.BaseAddress.ToInt64(),iconic,register,state);
            if (!Verify(p,hwnd,cef.BaseAddress.ToInt64(),state,iconic)) throw new InvalidOperationException("Post-apply verification failed.");
            Log("Applied and verified " + windowKey);
        } catch (Exception e) { Log("Guard failed " + key + ": " + e.Message); }
    }
    static int RunWorker(bool checkOnly) {
        using (Mutex mutex = new Mutex(false,MutexName("Worker"))) {
            bool owned = false;
            try {
                if (!checkOnly) {
                    owned = Own(mutex);
                    if (!owned) return 0;
                    using (Process self = Process.GetCurrentProcess()) Log("Worker started PID=" + self.Id);
                }
                do {
                    if (!checkOnly && StopRequested()) break;
                    Process[] processes = Process.GetProcessesByName("Spotify");
                    try {
                        foreach (Process p in processes) {
                            try { Handle(p,checkOnly); }
                            catch (Exception e) { Log("Process scan: " + e.Message); }
                        }
                    } finally { foreach (Process p in processes) p.Dispose(); }
                    if (checkOnly) break;
                    Thread.Sleep(2000);
                } while (true);
                return 0;
            }
            finally { if (owned) mutex.ReleaseMutex(); }
        }
    }
    static bool WaitForStop(int milliseconds) {
        Stopwatch timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < milliseconds) {
            if (StopRequested()) return true;
            Thread.Sleep(250);
        }
        return StopRequested();
    }
    static int RunSupervisor() {
        using (Mutex mutex = new Mutex(false,MutexName("Supervisor"))) {
            bool owned = Own(mutex);
            if (!owned) return 0;
            try {
                string executable;
                using (Process self = Process.GetCurrentProcess()) {
                    executable = self.MainModule.FileName;
                    Log("Supervisor started PID=" + self.Id);
                }
                int failures = 0;
                while (!StopRequested()) {
                    // A surviving worker is adopted after a supervisor restart.
                    if (WorkerRunning()) {
                        Log("Existing worker active; supervisor monitoring.");
                        while (!StopRequested() && WorkerRunning()) Thread.Sleep(1000);
                        if (StopRequested()) return 0;
                    }
                    Process child = null;
                    DateTime started = DateTime.UtcNow;
                    try {
                        child = Process.Start(new ProcessStartInfo {
                            FileName = executable, Arguments = "--worker", WorkingDirectory = Folder,
                            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden
                        });
                        if (child == null) throw new InvalidOperationException("Worker did not start.");
                        Log("Supervisor launched worker PID=" + child.Id);
                        // Never kill the worker while it could be inside native Apply.
                        // The stop file makes it exit at its next safe loop boundary.
                        while (!child.WaitForExit(1000)) { }
                        if (StopRequested()) return 0;
                        if (WorkerRunning()) continue;
                        if ((DateTime.UtcNow-started).TotalSeconds >= 60) failures = 0;
                        failures++;
                        Log("Worker exited unexpectedly, code=" + child.ExitCode + ", failure=" + failures);
                    } catch (Exception e) {
                        failures++;
                        Log("Worker supervision failed, failure=" + failures + ": " + e.Message);
                    } finally { if (child != null) child.Dispose(); }
                    if (failures >= 5) { Log("Worker restart limit reached."); return 1; }
                    int delay = Math.Min(30000,2000 << (failures-1));
                    if (WaitForStop(delay)) return 0;
                }
                return 0;
            } finally { mutex.ReleaseMutex(); }
        }
    }
    [STAThread]
    public static int Main(string[] args) {
        if (IntPtr.Size != 8) return 2;
        try {
            Directory.CreateDirectory(Folder);
            if (args.Length == 1 && args[0] == "--check") return RunWorker(true);
            if (args.Length == 1 && args[0] == "--worker") return RunWorker(false);
            if (args.Length != 0) return 2;
            return RunSupervisor();
        } catch (Exception e) { Log("Fatal: " + e); return 1; }
    }
}
