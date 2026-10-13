using System.IO;
using System.Text.Json;
using System.Windows;
using ScrcpyPicker.Services;
using ScrcpyPicker.ViewModels;
using ScrcpyPicker.Views;

namespace ScrcpyPicker;

/// <summary>命令行参数（沿用 Go 版的写法，前缀 - 与 -- 都认）。</summary>
public sealed record CliOptions
{
    public string ExeDir { get; init; } = AppContext.BaseDirectory;
    public string ToolsDir { get; init; } = string.Empty;
    public bool NoScan { get; init; }
    public bool SelfTest { get; init; }
    public string OutFile { get; init; } = string.Empty;

    public static CliOptions Parse(string[] args)
    {
        var o = new CliOptions();
        string exeDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        string tools = string.Empty;
        bool noScan = false, selfTest = false;
        string outFile = string.Empty;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            switch (a)
            {
                case "-tools" or "--tools":
                    if (i + 1 < args.Length) tools = args[++i];
                    break;
                case "-no-scan" or "--no-scan":
                    noScan = true;
                    break;
                case "--selftest" or "-selftest":
                    selfTest = true;
                    break;
                case "--out" or "-out":
                    if (i + 1 < args.Length) outFile = args[++i];
                    break;
            }
        }

        return o with
        {
            ExeDir = exeDir,
            ToolsDir = tools,
            NoScan = noScan,
            SelfTest = selfTest,
            OutFile = outFile,
        };
    }
}

/// <summary>
/// 程序入口。
///
/// 结构上与 Go 版一一对应：先解析工具链（可能触发一次自动搜索并记住结果），
/// 再把服务层交给视图模型。区别是没有 HTTP 服务和 WebView2 ——
/// 界面是原生 WPF，调用直接落到服务层。
/// </summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        CliOptions opt = CliOptions.Parse(e.Args);

        if (opt.SelfTest)
        {
            int code = SelfTest.Run(opt);
            Environment.ExitCode = code;
            Shutdown();
            return;
        }

        var backend = new PickerBackend(opt.ExeDir, opt.ToolsDir, allowScan: !opt.NoScan);
        var vm = new MainViewModel(backend);
        var win = new MainWindow { DataContext = vm };
        MainWindow = win;
        win.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        (MainWindow?.DataContext as MainViewModel)?.Stop();
        base.OnExit(e);
    }
}

/// <summary>
/// 无头自检：不建窗口，把服务层的解析结果、设备清单和版本信息打成 JSON 落到文件。
/// 发布后的 exe 用它做冒烟（不需要桌面会话，也不需要人工点界面）。
/// </summary>
internal static class SelfTest
{
    public static int Run(CliOptions opt)
    {
        var backend = new PickerBackend(opt.ExeDir, opt.ToolsDir, allowScan: !opt.NoScan);
        backend.Refresh(deep: false);

        var payload = new
        {
            exeDir = opt.ExeDir,
            noScan = opt.NoScan,
            status = backend.Status(),
            toolchain = backend.ToolchainState(),
            rows = backend.SnapshotRows(),
        };

        string json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        string target = opt.OutFile.Length > 0
            ? opt.OutFile
            : Path.Combine(Path.GetTempPath(), "scrcpy-picker-selftest.json");
        try
        {
            File.WriteAllText(target, json);
        }
        catch
        {
            // 落文件失败也不能崩：返回值仍然有效
        }

        var st = backend.Status();
        return st.AdbResolved ? 0 : 2; // 2 = 没找到 adb（是环境问题，不是代码问题）
    }
}
