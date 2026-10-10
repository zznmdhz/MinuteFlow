using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using MinuteFlow.Core;

namespace MinuteFlow.Windows;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        var smoke = args.Contains("--smoke-test");
        var root = smoke ? Path.Combine(Path.GetTempPath(), "MinuteFlow-smoke-" + Guid.NewGuid().ToString("N")) : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MinuteFlow");
        try
        {
            using var mutex = new Mutex(true, "Local\\MinuteFlow-" + Environment.UserName, out var created);
            if (!created && !smoke) { MessageBox.Show("MinuteFlow 已在运行，请从任务栏或系统托盘打开。", "MinuteFlow"); return 0; }
            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            var window = new MainWindow(root, smoke);
            app.DispatcherUnhandledException += (_, e) => { MessageBox.Show("操作未完成：" + e.Exception.Message + "\n已保存的录音仍可在会议目录查看。", "MinuteFlow"); e.Handled = true; };
            if (smoke)
            {
                app.Startup += (_, _) =>
                {
                    try
                    {
                        window.Show(); window.UpdateLayout();
                        window.PerformSmokeTest();
                        Console.WriteLine(JsonSerializer.Serialize(new { success = true, checks = new[] { "WPF-window", "history-and-transcript-controls", "1000-row-transcript-virtualization", "virtualized-edit-save-and-original-preservation", "read-only-title", "DPAPI-save-reload", "repository-rename-and-mtime", "synthetic-audio-mix", "settings-dialog" } }));
                        app.Shutdown(0);
                    }
                    catch (Exception e) { Console.Error.WriteLine(e); app.Shutdown(1); }
                };
            }
            else
            {
                var import = Array.IndexOf(args, "--import-wav");
                if (import >= 0 && import + 1 < args.Length) app.Startup += async (_, _) => await window.ImportAudioAsync(args[import + 1]);
            }
            var exit = app.Run(window);
            return exit;
        }
        catch (Exception error) { if (smoke) Console.Error.WriteLine(error); else MessageBox.Show(error.Message, "MinuteFlow 无法启动"); return 1; }
        finally { if (smoke && Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
