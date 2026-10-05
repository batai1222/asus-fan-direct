using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("直接操作你的华硕ProArt风扇")]
[assembly: AssemblyProduct("ASUS Fan Direct")]
[assembly: AssemblyDescription("ASUS ProArt H7600ZW fan preset controller")]
[assembly: AssemblyVersion("2026.10.5.1")]
[assembly: AssemblyFileVersion("2026.10.5.1")]

internal static class Program
{
    private const string Title = "直接操作你的华硕ProArt风扇";

    [STAThread]
    private static int Main(string[] args)
    {
        bool selfTest = args.Length == 1 && args[0] == "--self-test";
        try
        {
            if (args.Length != 0 && !selfTest)
                throw new ArgumentException("Supported argument: --self-test");

            if (!selfTest && !IsAdministrator())
            {
                ProcessStartInfo start = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location);
                start.UseShellExecute = true;
                start.Verb = "runas";
                using (Process elevated = Process.Start(start)) { }
                return 0;
            }

            if (!selfTest) EnsureInstalled();
            return RunController(selfTest);
        }
        catch (Win32Exception error)
        {
            if (error.NativeErrorCode == 1223) return 1223; // User cancelled elevation.
            return ReportError(error, selfTest);
        }
        catch (Exception error) { return ReportError(error, selfTest); }
    }

    private static bool IsAdministrator()
    {
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static string ReadResource(string name)
    {
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (stream == null) throw new InvalidOperationException("Missing embedded resource: " + name);
            using (StreamReader reader = new StreamReader(stream)) return reader.ReadToEnd();
        }
    }

    private static byte[] ReadResourceBytes(string name)
    {
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (stream == null) throw new InvalidOperationException("Missing embedded resource: " + name);
            using (MemoryStream buffer = new MemoryStream())
            {
                stream.CopyTo(buffer);
                return buffer.ToArray();
            }
        }
    }

    private static void CheckProtectedDirectory(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("安装目录不能使用目录链接。");
        CheckDirectoryRules(Directory.GetAccessControl(path).GetAccessRules(true, true, typeof(SecurityIdentifier)));
    }

    private static void CheckDirectoryRules(AuthorizationRuleCollection rules)
    {
        FileSystemRights write = FileSystemRights.WriteData | FileSystemRights.AppendData |
            FileSystemRights.WriteExtendedAttributes | FileSystemRights.WriteAttributes |
            FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0 ||
                (rule.FileSystemRights & write) == 0) continue;
            string sid = rule.IdentityReference.Value;
            if (sid != "S-1-5-18" && sid != "S-1-5-32-544" &&
                sid != "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")
                throw new InvalidOperationException("安装目录的权限不安全，请检查 Program Files 权限。");
        }
    }

    private static DirectorySecurity PackageDirectorySecurity()
    {
        DirectorySecurity security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
        InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        foreach (string sid in new string[] { "S-1-5-18", "S-1-5-32-544", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464" })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.ReadAndExecute, inheritance, PropagationFlags.None, AccessControlType.Allow));
        return security;
    }

    private static void CreateProtectedDirectory(string path)
    {
        if (!Directory.Exists(path)) Directory.CreateDirectory(path, PackageDirectorySecurity());
        CheckProtectedDirectory(path);
    }

    private static void EnsureInstalled()
    {
        using (Mutex mutex = new Mutex(false, @"Global\AsusFanDirect.PackageInstallation"))
        {
            bool locked = false;
            try
            {
                try { locked = mutex.WaitOne(30000); }
                catch (AbandonedMutexException) { locked = true; }
                if (!locked) throw new InvalidOperationException("另一份风扇程序正在配置，请稍后重试。");
                string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                CheckProtectedDirectory(programFiles);
                string parent = Path.Combine(programFiles, "ASUS Fan Direct");
                if (Directory.Exists(parent)) CheckProtectedDirectory(parent);
                CreateProtectedDirectory(parent);
                string package = Path.Combine(parent, "Package-" + Guid.NewGuid().ToString("N"));
                CreateProtectedDirectory(package);
                try
                {
                    CheckProtectedDirectory(package);
                    Directory.CreateDirectory(Path.Combine(package, "assets"));
                    File.WriteAllBytes(Path.Combine(package, "AsusFanDirect.ps1"), ReadResourceBytes("AsusFanDirect.ps1"));
                    File.WriteAllBytes(Path.Combine(package, "GpuSaioWorker.ps1"), ReadResourceBytes("GpuSaioWorker.ps1"));
                    File.WriteAllBytes(Path.Combine(package, "assets\\fan.ico"), ReadResourceBytes("fan.ico"));
                    File.Copy(Assembly.GetExecutingAssembly().Location, Path.Combine(package, "AsusFanDirect.exe"));
                    using (Runspace runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault()))
                    {
                        runspace.Open();
                        using (PowerShell shell = PowerShell.Create())
                        {
                            shell.Runspace = runspace;
                            shell.AddScript(ReadResource("Install.ps1")).AddParameter("PackageDirectory", package)
                                .AddParameter("EnsureInstalled", true)
                                .AddParameter("LauncherProcessId", Process.GetCurrentProcess().Id);
                            shell.Invoke();
                            if (shell.Streams.Error.Count != 0)
                                throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                        }
                    }
                }
                finally
                {
                    // Only this freshly generated directory under the checked Program Files parent.
                    if (Path.GetDirectoryName(Path.GetFullPath(package)) == parent && Directory.Exists(package))
                    {
                        CheckProtectedDirectory(package);
                        Directory.Delete(package, true);
                    }
                }
            }
            finally { if (locked) mutex.ReleaseMutex(); }
        }
    }

    private static int RunController(bool selfTest)
    {
        using (Runspace runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault()))
        {
            runspace.ApartmentState = ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();
            Runspace.DefaultRunspace = runspace;
            try
            {
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    string controller = ReadResource("AsusFanDirect.ps1");
                    if (selfTest)
                    {
                        shell.AddScript(ReadResource("Test-Bootstrap.ps1")).AddParameter("InstallerText", ReadResource("Install.ps1"));
                        foreach (PSObject item in shell.Invoke())
                            if (item != null) Console.WriteLine(item.ToString());
                        if (shell.Streams.Error.Count != 0)
                            throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                        shell.Commands.Clear();
                        shell.AddScript(ReadResource("Test-FanController.ps1")).AddParameter("SourceText", controller);
                    }
                    else
                        shell.AddScript(controller).AddParameter("Mode", "Gui");

                    foreach (PSObject item in shell.Invoke())
                        if (selfTest && item != null) Console.WriteLine(item.ToString());

                    if (shell.Streams.Error.Count != 0)
                        throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                }
                if (selfTest)
                {
                    CheckDirectoryRules(PackageDirectorySecurity().GetAccessRules(true, true, typeof(SecurityIdentifier)));
                    // Check the same desktop and threading dependencies without showing a window.
                    using (Form form = new Form())
                    {
                        form.Text = Title;
                        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
                            throw new InvalidOperationException("The GUI requires an STA thread.");
                        IntPtr handle = form.Handle;
                        if (handle == IntPtr.Zero) throw new InvalidOperationException("Window creation failed.");
                    }
                    Console.WriteLine("PASS: embedded controller, Windows PowerShell host, and GUI dependencies.");
                }
                return 0;
            }
            finally { Runspace.DefaultRunspace = null; }
        }
    }

    private static int ReportError(Exception error, bool selfTest)
    {
        if (selfTest) Console.Error.WriteLine(error.ToString());
        else MessageBox.Show(error.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        return 1;
    }
}
