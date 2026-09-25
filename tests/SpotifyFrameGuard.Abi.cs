using System;
using System.Runtime.InteropServices;
public static class GuardAbiTest {
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int Iconic(IntPtr h);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int Guard(IntPtr h);
 static bool minimized;
 static int calls;
 static Iconic callback = Check;
 static int Check(IntPtr h) { calls++; if(h.ToInt64()!=0x1234)throw new Exception("Wrong HWND passed to predicate"); return minimized?0x20000000:0; }
 public static long Predicate() { return Marshal.GetFunctionPointerForDelegate(callback).ToInt64(); }
 [DllImport("kernel32.dll")] static extern IntPtr VirtualAlloc(IntPtr at,UIntPtr n,uint kind,uint protect);
 [DllImport("kernel32.dll")] static extern bool VirtualProtect(IntPtr p,UIntPtr n,uint protect,out uint old);
 [DllImport("kernel32.dll")] static extern bool VirtualFree(IntPtr p,UIntPtr n,uint kind);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] static extern bool FlushInstructionCache(IntPtr p,IntPtr at,UIntPtr n);
 [DllImport("ntdll.dll")] [return:MarshalAs(UnmanagedType.U1)] static extern bool RtlAddFunctionTable(IntPtr t,uint count,ulong imageBase);
 [DllImport("ntdll.dll")] [return:MarshalAs(UnmanagedType.U1)] static extern bool RtlDeleteFunctionTable(IntPtr t);
 public static string Run(byte[] code) {
  IntPtr page=VirtualAlloc(IntPtr.Zero,(UIntPtr)4096,0x3000,4);
  if(page==IntPtr.Zero)throw new Exception("Allocation failed");
  IntPtr h=Marshal.AllocHGlobal(0x300), d=Marshal.AllocHGlobal(0x200);
  IntPtr table=new IntPtr(page.ToInt64()+0x180);
  bool registered=false;
  try {
   Marshal.Copy(code,0,page,code.Length);
   byte[] unwind={1,4,1,0,4,0x42,0,0}; Marshal.Copy(unwind,0,new IntPtr(page.ToInt64()+0x100),8);
   Marshal.WriteInt32(table,0,0); Marshal.WriteInt32(table,4,code.Length); Marshal.WriteInt32(table,8,0x100);
   uint old; if(!VirtualProtect(page,(UIntPtr)4096,0x20,out old))throw new Exception("Protection failed");
   if(!FlushInstructionCache(GetCurrentProcess(),page,(UIntPtr)4096))throw new Exception("Instruction cache flush failed");
   registered=RtlAddFunctionTable(table,1,(ulong)page.ToInt64()); if(!registered)throw new Exception("Unwind registration failed");
   Guard guard=(Guard)Marshal.GetDelegateForFunctionPointer(page,typeof(Guard));
   Marshal.WriteIntPtr(h,0x60,d);
   int checkedCases=0;
   foreach(bool same in new[]{false,true})foreach(bool iconic in new[]{false,true})foreach(bool hasFrame in new[]{false,true}) {
    Marshal.WriteIntPtr(h,0x40,new IntPtr(same?0x1234:0x4321));
    Marshal.WriteByte(d,0xEB,(byte)(hasFrame?0:1)); minimized=iconic;calls=0;
    int actual=guard(h)&0xFF,expected=(same&&iconic)||hasFrame?1:0;
    if(actual!=expected || calls!=(same?1:0))throw new Exception("ABI/predicate mismatch");
    checkedCases++;
   }
   GC.KeepAlive(callback); return "PASS: "+checkedCases+" native wrapper cases, including non-boolean BOOL bits and non-target HWND bypass";
  } finally { if(registered)RtlDeleteFunctionTable(table);Marshal.FreeHGlobal(h);Marshal.FreeHGlobal(d);VirtualFree(page,UIntPtr.Zero,0x8000); }
 }
}
