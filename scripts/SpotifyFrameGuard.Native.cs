// Experimental, session-only guard for the verified CEF 146 build.
// No on-disk executable is modified. Restarting Spotify removes the guard.
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text.RegularExpressions;

public sealed class SpotifyFrameGuardState {
    public int ProcessId;
    public int ThreadId;
    public long ProcessStartTicks;
    public long Site;
    public long Page;
    public string OriginalHex;
    public string PatchedHex;
}

public static class SpotifyFrameGuardNative {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenThread(uint access, bool inherit, int id);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetProcessIdOfThread(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr p, IntPtr at, byte[] data, UIntPtr n, out UIntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool WriteProcessMemory(IntPtr p, IntPtr at, byte[] data, UIntPtr n, out UIntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr at, UIntPtr size, uint flags, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool VirtualProtectEx(IntPtr p, IntPtr at, UIntPtr size, uint protect, out uint old);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FlushInstructionCache(IntPtr p, IntPtr at, UIntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint SuspendThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetThreadContext(IntPtr thread, IntPtr context);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateRemoteThread(IntPtr p, IntPtr attr, UIntPtr stack, IntPtr start, IntPtr arg, uint flags, out uint id);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeThread(IntPtr h, out uint code);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true)] public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);

    static readonly byte[] Original = Hex("488B4E60E83CF75800");
    static Exception Error(string action) { return new Win32Exception(Marshal.GetLastWin32Error(), action); }
    static byte[] Hex(string s) { byte[] b=new byte[s.Length/2]; for(int i=0;i<b.Length;i++) b[i]=Convert.ToByte(s.Substring(i*2,2),16); return b; }
    static string HexText(byte[] b) { return BitConverter.ToString(b).Replace("-", ""); }
    static bool Equal(byte[] a, byte[] b) { if(a.Length!=b.Length)return false; for(int i=0;i<a.Length;i++)if(a[i]!=b[i])return false; return true; }
    static byte[] Read(IntPtr p,long at,int size) { byte[] b=new byte[size]; UIntPtr n; if(!ReadProcessMemory(p,new IntPtr(at),b,(UIntPtr)size,out n)||n.ToUInt64()!=(ulong)size)throw Error("ReadProcessMemory"); return b; }
    static void Write(IntPtr p,long at,byte[] b) { UIntPtr n; if(!WriteProcessMemory(p,new IntPtr(at),b,(UIntPtr)b.Length,out n)||n.ToUInt64()!=(ulong)b.Length)throw Error("WriteProcessMemory"); }
    static void Put(byte[] b,int offset,byte[] value) { Buffer.BlockCopy(value,0,b,offset,value.Length); }
    static byte[] Rel32(long target,long next) { return BitConverter.GetBytes(checked((int)(target-next))); }

    // The instruction site is shared, so suspend every process thread while
    // exchanging its non-atomic bytes. Never overwrite an executing instruction.
    static void Exchange(IntPtr process,int pid,int threadId,long site,byte[] expected,byte[] replacement) {
        IntPtr storage=Marshal.AllocHGlobal(1280);
        IntPtr context=new IntPtr((storage.ToInt64()+15)&~15L);
        try {
            for(int attempt=0;attempt<10;attempt++) {
                List<IntPtr> threads=new List<IntPtr>();
                HashSet<int> ids=new HashSet<int>();
                bool busy=false;
                try {
                    for(int pass=0;pass<4;pass++) {
                        bool added=false;
                        using(Process target=Process.GetProcessById(pid)) {
                            foreach(ProcessThread t in target.Threads) {
                                if(ids.Contains(t.Id))continue;
                                // SYNCHRONIZE lets us distinguish an exited thread if resume fails.
                                IntPtr handle=OpenThread(0x10004A,false,t.Id);
                                if(handle==IntPtr.Zero)throw Error("Open target thread");
                                if(GetProcessIdOfThread(handle)!=(uint)pid) { CloseHandle(handle); throw new InvalidOperationException("Thread owner changed."); }
                                uint count=SuspendThread(handle);
                                if(count==UInt32.MaxValue) { CloseHandle(handle); throw Error("Suspend target thread"); }
                                threads.Add(handle); ids.Add(t.Id); added=true;
                                if(count!=0)throw new InvalidOperationException("A target thread was already suspended.");
                            }
                        }
                        if(!added)break;
                        if(pass==3)throw new InvalidOperationException("Process thread set did not stabilize.");
                    }
                    if(!ids.Contains(threadId))throw new InvalidOperationException("Main thread changed.");
                    foreach(IntPtr handle in threads) {
                        Marshal.WriteInt32(context,48,0x100001);
                        if(!GetThreadContext(handle,context))throw Error("GetThreadContext");
                        long rip=Marshal.ReadInt64(context,248);
                        if(rip>=site && rip<site+expected.Length)busy=true;
                    }
                    if(busy)continue;
                if(!Equal(Read(process,site,expected.Length),expected))throw new InvalidOperationException("Live instruction bytes differ; refusing to overwrite them.");
                uint oldProtect;
                if(!VirtualProtectEx(process,new IntPtr(site),(UIntPtr)expected.Length,0x40,out oldProtect))throw Error("VirtualProtectEx site");
                try {
                    try { Write(process,site,replacement); if(!Equal(Read(process,site,replacement.Length),replacement))throw new InvalidOperationException("Patch readback failed."); }
                    catch { Write(process,site,expected); throw; }
                }
                finally {
                    uint unused;
                    bool protectionRestored=VirtualProtectEx(process,new IntPtr(site),(UIntPtr)expected.Length,oldProtect,out unused);
                    bool cacheFlushed=FlushInstructionCache(process,new IntPtr(site),(UIntPtr)expected.Length);
                    if(!protectionRestored||!cacheFlushed)throw Error("Restore code protection/cache");
                }
                return;
                }
                finally {
                    Exception resumeError=null;
                    for(int i=threads.Count-1;i>=0;i--) {
                        IntPtr handle=threads[i];
                        try {
                            if(ResumeThread(handle)==UInt32.MaxValue) {
                                int errorCode=Marshal.GetLastWin32Error();
                                if(WaitForSingleObject(handle,0)!=0 && resumeError==null)
                                    resumeError=new Win32Exception(errorCode,"Resume target thread");
                            }
                        }
                        finally { CloseHandle(handle); }
                    }
                    if(resumeError!=null)throw resumeError;
                }
            }
            throw new InvalidOperationException("UI thread remained in the patch region; no patch applied.");
        }
        finally { Marshal.FreeHGlobal(storage); }
    }

    public static byte[] BuildWrapper(long hwnd,long isIconic) {
        List<byte> code=new List<byte>();
        code.AddRange(Hex("4883EC2848894C2420488B494048B8")); code.AddRange(BitConverter.GetBytes(hwnd));
        code.AddRange(Hex("4839C1")); int fallbackJump=code.Count; code.AddRange(Hex("7500"));
        code.AddRange(Hex("48B8")); code.AddRange(BitConverter.GetBytes(isIconic));
        code.AddRange(Hex("FFD085C0")); int iconicJump=code.Count; code.AddRange(Hex("7500"));
        int fallback=code.Count;
        code.AddRange(Hex("488B4C2420488B49608A81EB00000034014883C428C3"));
        int iconic=code.Count; code.AddRange(Hex("B8010000004883C428C3"));
        code[fallbackJump+1]=checked((byte)(fallback-fallbackJump-2));
        code[iconicJump+1]=checked((byte)(iconic-iconicJump-2));
        return code.ToArray();
    }

    public static SpotifyFrameGuardState Apply(int pid,int tid,long hwnd,long moduleBase,long isIconic,long addFunctionTable,string statePath) {
        if(IntPtr.Size!=8)throw new InvalidOperationException("64-bit PowerShell is required.");
        long site=moduleBase+0x1D1312B;
        IntPtr process=OpenProcess(0x43A,false,pid);
        if(process==IntPtr.Zero)throw Error("OpenProcess");
        try {
            if(!Equal(Read(process,site,Original.Length),Original))throw new InvalidOperationException("Unsupported live CEF bytes, or guard already applied.");
            long aligned=(site+0xFFFF)&~0xFFFFL;
            IntPtr page=IntPtr.Zero;
            for(int i=1;i<=8192 && page==IntPtr.Zero;i++) {
                long delta=(long)i*0x10000;
                page=VirtualAllocEx(process,new IntPtr(aligned+delta),(UIntPtr)4096,0x3000,4);
                if(page==IntPtr.Zero && aligned>delta)page=VirtualAllocEx(process,new IntPtr(aligned-delta),(UIntPtr)4096,0x3000,4);
            }
            if(page==IntPtr.Zero)throw Error("Allocate near code");
            long baseAddress=page.ToInt64();
            // Wrapper bool(handler): IsIconic(hwnd) || original HasFrame predicate.
            // Separate CALL frame and registered unwind info preserve x64 unwinding.
            byte[] wrapper=BuildWrapper(hwnd,isIconic);
            byte[] pageData=new byte[4096]; Put(pageData,0,wrapper);
            // UNWIND_INFO: version=1, prologue=4, one ALLOC_SMALL(40) operation.
            Put(pageData,0x100,Hex("0104010004420000"));
            // Leaf initializer tail-calls RtlAddFunctionTable(table,1,pageBase).
            // It has no stack frame needing registration before this first call.
            byte[] init=Hex("48B90000000000000000BA0100000049B8000000000000000048B80000000000000000FFE0");
            Put(init,2,BitConverter.GetBytes(baseAddress+0x180));
            Put(init,17,BitConverter.GetBytes(baseAddress));
            Put(init,27,BitConverter.GetBytes(addFunctionTable));
            Put(pageData,0x200,init);
            Put(pageData,0x180,BitConverter.GetBytes((uint)0));
            Put(pageData,0x184,BitConverter.GetBytes((uint)wrapper.Length));
            Put(pageData,0x188,BitConverter.GetBytes((uint)0x100));
            Write(process,baseAddress,pageData);
            uint old;
            if(!VirtualProtectEx(process,page,(UIntPtr)4096,0x20,out old))throw Error("Protect wrapper executable");
            if(!FlushInstructionCache(process,page,(UIntPtr)4096))throw Error("Flush wrapper");
            uint remoteId;
            IntPtr initThread=CreateRemoteThread(process,IntPtr.Zero,UIntPtr.Zero,new IntPtr(baseAddress+0x200),IntPtr.Zero,0,out remoteId);
            if(initThread==IntPtr.Zero)throw Error("Register unwind table thread");
            try {
                uint exit;
                if(WaitForSingleObject(initThread,5000)!=0)throw new InvalidOperationException("Unwind registration did not finish. Restart Spotify before retrying.");
                if(!GetExitCodeThread(initThread,out exit)||(exit & 0xFF)!=1)throw new InvalidOperationException("Unwind table registration failed; no code-site patch applied.");
            } finally { CloseHandle(initThread); }
            // Keep the CALL return address at the original instruction boundary
            // site+9, including if Undo runs while the wrapper is executing.
            byte[] patch=Hex("4889F190E800000000");
            Put(patch,5,Rel32(baseAddress,site+9));
            SpotifyFrameGuardState state=new SpotifyFrameGuardState { ProcessId=pid,ThreadId=tid,
                ProcessStartTicks=Process.GetProcessById(pid).StartTime.ToUniversalTime().Ticks,
                Site=site,Page=baseAddress,OriginalHex=HexText(Original),PatchedHex=HexText(patch) };
            string recovery=String.Format(System.Globalization.CultureInfo.InvariantCulture,
                "{{\"ProcessId\":{0},\"ThreadId\":{1},\"ProcessStartTicks\":{2},\"Site\":{3},\"Page\":{4},\"OriginalHex\":\"{5}\",\"PatchedHex\":\"{6}\"}}",
                state.ProcessId,state.ThreadId,state.ProcessStartTicks,state.Site,state.Page,state.OriginalHex,state.PatchedHex);
            using(var file=new System.IO.FileStream(statePath,System.IO.FileMode.CreateNew,System.IO.FileAccess.Write,System.IO.FileShare.Read))
            using(var writer=new System.IO.StreamWriter(file,new System.Text.UTF8Encoding(false))) { writer.Write(recovery); }
            Exchange(process,pid,tid,site,Original,patch);
            return state;
        }
        finally { CloseHandle(process); }
    }

    public static void Undo(int pid,int tid,long startTicks,long site,long page,string originalHex,string patchHex,long moduleBase) {
        if(site!=checked(moduleBase+0x1D1312B) || !String.Equals(originalHex,HexText(Original),StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Recovery state does not match the verified CEF module.");
        if((page & 0xFFFF)!=0 || !Regex.IsMatch(patchHex??"",@"\A4889F190E8[0-9A-F]{8}\z",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Recovery patch has an invalid format.");
        byte[] patch=Hex(patchHex);
        if(checked(site+9+(long)BitConverter.ToInt32(patch,5))!=page)
            throw new InvalidOperationException("Recovery patch does not target its registered code page.");
        if(Process.GetProcessById(pid).StartTime.ToUniversalTime().Ticks!=startTicks)throw new InvalidOperationException("Process has changed; this guard no longer applies.");
        IntPtr process=OpenProcess(0x438,false,pid);
        if(process==IntPtr.Zero)throw Error("OpenProcess undo");
        try { Exchange(process,pid,tid,site,patch,Original); }
        finally { CloseHandle(process); }
        // Keep the 4 KB registered code/table alive until process exit: a caller
        // could still be returning through it. No timer or worker remains active.
    }
}
