using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;

namespace BluetoothRepairLauncher
{
    class Program
    {
        static int Main(string[] args)
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            bool isAdmin = principal.IsInRole(WindowsBuiltInRole.Administrator);

            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string psScriptPath = Path.Combine(exeDir, "Repair-IntelAX211Bluetooth.ps1");

            if (!File.Exists(psScriptPath))
            {
                Console.WriteLine("[ERROR] Companion PowerShell script not found at: " + psScriptPath);
                Console.WriteLine("Press any key to exit...");
                Console.ReadKey();
                return 1;
            }

            string argString = "-NoProfile -ExecutionPolicy Bypass -File \"" + psScriptPath + "\"";
            foreach (string arg in args)
            {
                argString += " \"" + arg + "\"";
            }

            if (!isAdmin)
            {
                try
                {
                    ProcessStartInfo startInfo = new ProcessStartInfo();
                    startInfo.FileName = "powershell.exe";
                    startInfo.Arguments = argString;
                    startInfo.Verb = "runas";
                    startInfo.UseShellExecute = true;

                    Process proc = Process.Start(startInfo);
                    proc.WaitForExit();
                    return proc.ExitCode;
                }
                catch (Exception ex)
                {
                    Console.WriteLine("[ERROR] Failed to elevate process: " + ex.Message);
                    return 1;
                }
            }
            else
            {
                try
                {
                    ProcessStartInfo startInfo = new ProcessStartInfo();
                    startInfo.FileName = "powershell.exe";
                    startInfo.Arguments = argString;
                    startInfo.UseShellExecute = false;

                    Process proc = Process.Start(startInfo);
                    proc.WaitForExit();
                    return proc.ExitCode;
                }
                catch (Exception ex)
                {
                    Console.WriteLine("[ERROR] Failed to execute PowerShell script: " + ex.Message);
                    return 1;
                }
            }
        }
    }
}
