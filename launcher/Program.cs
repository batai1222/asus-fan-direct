using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("直接操作你的华硕ProArt风扇")]
[assembly: AssemblyProduct("ASUS Fan Direct")]
[assembly: AssemblyDescription("ASUS ProArt H7600ZW fan preset controller")]
[assembly: AssemblyVersion("2026.9.19.2")]
[assembly: AssemblyFileVersion("2026.9.19.2")]

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
                        shell.AddScript(ReadResource("Test-FanController.ps1")).AddParameter("SourceText", controller);
                    else
                        shell.AddScript(controller).AddParameter("Mode", "Gui");

                    foreach (PSObject item in shell.Invoke())
                        if (selfTest && item != null) Console.WriteLine(item.ToString());

                    if (shell.Streams.Error.Count != 0)
                        throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                }
                if (selfTest)
                {
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
