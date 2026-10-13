using System.IO;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 投屏参数、日志判读与命令行解析——三处都不需要真机，也都不该靠人工点出来验证。
/// </summary>
public class CastAndCliTests
{
    private static CastManager Manager() => new(new ToolchainHolder(ToolchainSnapshot.Empty));

    // ---- scrcpy 启动参数 ----

    [Fact]
    public void ArgList_isTheExactCommandLineTheOldFrontendUsed()
    {
        List<string> a = CastManager.ArgList("c1e5d47a", noClipboard: false);

        Assert.Equal(new List<string>
        {
            "-s", "c1e5d47a", "-m", "1280", "-b", "4M", "--max-fps=60",
            "--window-title", "c1e5d47a", "--shortcut-mod=lalt,lsuper",
        }, a);
    }

    [Fact]
    public void ArgList_addsTheClipboardSwitchOnlyWhenAsked()
    {
        int baseCount = CastManager.ArgList("x", noClipboard: false).Count;
        List<string> a = CastManager.ArgList("x", noClipboard: true);

        Assert.Equal(baseCount + 1, a.Count);
        Assert.Contains("--no-clipboard-autosync", a);
        // 开关只追加在末尾，前面那串参数一字不改
        Assert.False(a[0].StartsWith("--", StringComparison.Ordinal));
    }

    [Fact]
    public void ArgList_keepsShortcutMod_soAltBHStillWork()
    {
        // 不显式写 --shortcut-mod，scrcpy 5.0 的默认修饰键会变，Alt+B/H/S 就废了
        Assert.Contains("--shortcut-mod=lalt,lsuper", CastManager.ArgList("x", noClipboard: false));
    }

    // ---- 日志判读 ----

    private static string WriteLog(string body)
    {
        string path = Path.Combine(Path.GetTempPath(),
            "picker-castlog-" + Guid.NewGuid().ToString("N")[..8] + ".err");
        File.WriteAllText(path, body);
        return path;
    }

    [Theory]
    [InlineData("[server] INFO: Device: [Xiaomi] Xiaomi Mi 10 Pro")]
    [InlineData("scrcpy 5.0 (<hash>)")]
    [InlineData("DEBUG: Renderer: direct3d11")]
    [InlineData("New texture: 1920x1080")]
    public void IsReady_acceptsAnyOfTheScrcpySignals(string logLine)
    {
        string path = WriteLog(logLine + Environment.NewLine);
        try
        {
            Assert.True(Manager().IsReady(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void IsReady_isFalseBeforeTheWindowReallyExists()
    {
        // "进程起来了"≠"正在投屏"：只有这几行日志出现才算连上
        string path = WriteLog("ERROR: Could not connect to device\n");
        try
        {
            Assert.False(Manager().IsReady(path));
        }
        finally
        {
            File.Delete(path);
        }

        Assert.False(Manager().IsReady(string.Empty));
        Assert.False(Manager().IsReady(Path.Combine(Path.GetTempPath(), "no-such-cast-log.err")));
    }

    [Fact]
    public void IsReady_alsoLooksAtTheStdoutSidecar()
    {
        string path = WriteLog(string.Empty);
        string outPath = path + ".out";
        File.WriteAllText(outPath, "[server] INFO: Device: x\n");
        try
        {
            Assert.True(Manager().IsReady(path));
        }
        finally
        {
            File.Delete(path);
            File.Delete(outPath);
        }
    }

    [Fact]
    public void LogSummary_joinsTheFirstEightNonEmptyLines()
    {
        var body = string.Join("\n", Enumerable.Range(1, 12).Select(i => $"line{i}"));
        string path = WriteLog("  \n" + body + "\n\n");
        try
        {
            string got = Manager().LogSummary(path);
            Assert.Equal("line1 line2 line3 line4 line5 line6 line7 line8", got);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void LogSummary_onMissingOrEmptyLog_isEmpty_notAnException()
    {
        Assert.Equal(string.Empty, Manager().LogSummary(string.Empty));
        Assert.Equal(string.Empty, Manager().LogSummary(Path.Combine(Path.GetTempPath(), "no-such-cast-log.err")));
    }

    // ---- 进程存活判定 ----

    [Fact]
    public void IsAlive_rejectsPidZero_andSomeoneElsesProcess()
    {
        CastManager m = Manager();
        Assert.False(m.IsAlive(0));
        Assert.False(m.IsAlive(-1));
        // 当前进程活着，但它不是 scrcpy：PID 被回收后不能误判成"还在投屏"
        Assert.False(m.IsAlive(Environment.ProcessId));
    }

    // ---- 命令行 ----

    [Fact]
    public void CliOptions_parsesBothDashStyles()
    {
        CliOptions o = CliOptions.Parse(new[] { "-tools", @"E:\tools", "--no-scan", "--selftest", "--out", @"C:\tmp\o.json" });

        Assert.Equal(@"E:\tools", o.ToolsDir);
        Assert.True(o.NoScan);
        Assert.True(o.SelfTest);
        Assert.Equal(@"C:\tmp\o.json", o.OutFile);
    }

    [Fact]
    public void CliOptions_defaultsAreGuiModeWithScanAllowed()
    {
        CliOptions o = CliOptions.Parse(Array.Empty<string>());

        Assert.False(o.SelfTest);
        Assert.False(o.NoScan);
        Assert.Equal(string.Empty, o.ToolsDir);
        Assert.Equal(string.Empty, o.OutFile);
        // exe 目录去掉尾分隔符：拼 tools 时不会出现双斜杠
        Assert.False(string.IsNullOrEmpty(o.ExeDir));
        Assert.False(o.ExeDir.EndsWith(Path.DirectorySeparatorChar));
    }

    [Fact]
    public void CliOptions_ignoresUnknownArgs_andToleratesAMissingValue()
    {
        CliOptions o = CliOptions.Parse(new[] { "--verbose", "-tools" });

        // -tools 是最后一个参数且没有值：不能把数组读越界
        Assert.Equal(string.Empty, o.ToolsDir);
        Assert.False(o.NoScan);
    }

    // ---- 外部命令执行器 ----

    [Fact]
    public void ProcessRunner_missingExecutable_reportsFailureWithoutThrowing()
    {
        // adb / scrcpy 不存在时调用方要按"没有输出"处理，绝不能报成"设备不存在"
        CmdResult r = ProcessRunner.Run(
            Path.Combine(Path.GetTempPath(), "definitely-not-an-exe-" + Guid.NewGuid().ToString("N")[..8] + ".exe"),
            new[] { "devices" });

        Assert.Equal(-1, r.Status);
        Assert.Empty(r.Lines);
        Assert.Equal(string.Empty, r.Text);
    }

    [Fact]
    public void ProcessRunner_capturesStdoutOfARealProcess()
    {
        CmdResult r = ProcessRunner.Run(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "cmd.exe"),
            new[] { "/c", "echo picker" }, timeoutMs: 10000);

        Assert.Equal(0, r.Status);
        Assert.True(r.Text.Contains("picker", StringComparison.Ordinal));
    }

    [Fact]
    public void SplitLines_matchesTheGoTrimmingRules()
    {
        Assert.Equal(Array.Empty<string>(), ProcessRunner.SplitLines(string.Empty));
        Assert.Equal(new[] { "a", "b" }, ProcessRunner.SplitLines("a\r\nb\t"));
        // 结尾换行会留一个空项：与 Go 的 strings.Split 一致，调用方按内容判断而不是按行数
        Assert.Equal(new[] { "a", "" }, ProcessRunner.SplitLines("a\n"));
    }
}
