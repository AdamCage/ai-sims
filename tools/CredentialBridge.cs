// Small Windows Credential Manager bridge. Secrets travel only over inherited
// anonymous pipes, never command-line arguments or temporary plaintext files.
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
class CredentialBridge {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CredWriteW(ref Credential credential,uint flags);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CredReadW(string target,uint type,uint flags,out IntPtr credential);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CredDeleteW(string target,uint type,uint flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);
    // One live writer per account ledger, independent of game saves. The named
    // mutex is released by Windows even if this process is killed or crashes.
    static int LedgerLease(string[] args) {
        int parentId;
        if(args.Length!=3 || args[1].Length!=64 || !Int32.TryParse(args[2],out parentId)) { Console.WriteLine("busy");return 2; }
        foreach(char c in args[1]) if(!((c>='0'&&c<='9')||(c>='a'&&c<='f'))) { Console.WriteLine("busy");return 2; }
        using(Mutex mutex=new Mutex(false,"Local\\AdamCage.AISims.Ledger."+args[1])) {
            bool acquired=false;
            try {
                try { acquired=mutex.WaitOne(250); } catch(AbandonedMutexException) { acquired=true; }
                if(!acquired) { Console.WriteLine("busy");Console.Out.Flush();return 0; }
                using(Process parent=Process.GetProcessById(parentId)) {
                    Console.WriteLine("locked");Console.Out.Flush();
                    Task<string> input=Console.In.ReadLineAsync();
                    while(!input.Wait(250)) if(parent.HasExited)return 0;
                }
            } finally { if(acquired)mutex.ReleaseMutex(); }
        }
        return 0;
    }
    static int Main(string[] args) {
        try {
            string target="AdamCage.AISims.RouterAI"+(args.Length>1 && args[1]=="test" ? ".Test" : "");
            string op=args.Length>0 ? args[0] : "";
            if(op=="ledger-lease")return LedgerLease(args);
            if(op=="put") {
                byte[] bytes=Convert.FromBase64String(Console.ReadLine()??"");
                if(bytes.Length<1||bytes.Length>2048) {Console.WriteLine("ERROR:invalid_length");return 2;}
                IntPtr p=Marshal.AllocHGlobal(bytes.Length);
                try {
                    Marshal.Copy(bytes,0,p,bytes.Length);
                    Credential c=new Credential();c.Type=1;c.TargetName=target;c.UserName="RouterAI";
                    c.CredentialBlob=p;c.CredentialBlobSize=(uint)bytes.Length;c.Persist=2;
                    Console.WriteLine(CredWriteW(ref c,0)?"OK:":"ERROR:write_failed");
                } finally {for(int i=0;i<bytes.Length;i++)Marshal.WriteByte(p,i,0);Marshal.FreeHGlobal(p);Array.Clear(bytes,0,bytes.Length);}
            } else if(op=="get") {
                IntPtr p;
                if(!CredReadW(target,1,0,out p)) {Console.WriteLine("OK:");return 0;}
                try {Credential c=(Credential)Marshal.PtrToStructure(p,typeof(Credential));byte[] bytes=new byte[c.CredentialBlobSize];Marshal.Copy(c.CredentialBlob,bytes,0,bytes.Length);Console.WriteLine("OK:"+Convert.ToBase64String(bytes));Array.Clear(bytes,0,bytes.Length);}
                finally {CredFree(p);}
            } else if(op=="delete") {CredDeleteW(target,1,0);Console.WriteLine("OK:");}
            else {Console.WriteLine("ERROR:invalid_operation");return 2;}
            return 0;
        } catch {Console.WriteLine("ERROR:credential_operation_failed");return 1;}
    }
}
