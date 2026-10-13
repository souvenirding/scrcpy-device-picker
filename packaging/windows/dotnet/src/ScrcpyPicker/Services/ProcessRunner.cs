using System.Diagnostics;
using System.Text;

namespace ScrcpyPicker.Services;

/// <summary>一次外部命令的结果。</summary>
/// <param name="Status">退出码；启动失败记 -1（与 Go 版 Run 的约定一致）。</param>
/// <param name="Lines">合并输出按 \n 切行，每行去掉尾部 \r 空格制表符。</param>
/// <param name="Text">合并后的原始文本。</param>
public readonly record struct CmdResult(int Status, string[] Lines, string Text);

/// <summary>
/// 外部命令执行器（对应 Go 版 toolchain.Run / Adb / AdbText / ShellProp）。
///
/// 三个容易踩的点在这里一次性固定：
///   1. stdout 与 stderr 先双双挂上异步读取再等退出，否则缓冲区写满时父子互等、命令永远不返回；
///   2. 编码显式设成 UTF-8。不指定时 .NET 按当前代码页（本机 GBK）解码，
///      而 adb shell 返回的是 UTF-8，设备名里的中文会变乱码——旧 PowerShell 版就是这么坏的；
///   3. 有超时并强杀，adb server 卡住时不能把界面拖死。
///
/// 方法是同步阻塞的（与 Go 版一致，调用点都在后台线程/刷新循环里）：**绝不要在 UI 线程调用**。
/// </summary>
public static class ProcessRunner
{
    private static readonly UTF8Encoding Utf8NoBom = new(false);

    public static CmdResult Run(string exe, IEnumerable<string> args, int timeoutMs = 15000)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Utf8NoBom,
            StandardErrorEncoding = Utf8NoBom,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        try
        {
            using var p = Process.Start(psi);
            if (p is null) return new CmdResult(-1, Array.Empty<string>(), string.Empty);

            Task<string> outTask = p.StandardOutput.ReadToEndAsync();
            Task<string> errTask = p.StandardError.ReadToEndAsync();

            bool exited = p.WaitForExit(timeoutMs);
            if (!exited)
            {
                try { p.Kill(entireProcessTree: true); } catch { /* 正好自己退了 */ }
            }
            // 再等一次无参 WaitForExit：等的是异步输出读Complete，
            // 少了这一步，ReadToEndAsync 可能还在半路上。
            try { p.WaitForExit(); } catch { /* 已 Dispose 竞态 */ }

            string stdout = AwaitText(outTask);
            string stderr = AwaitText(errTask);
            int status = p.HasExited ? p.ExitCode : -1;

            string text = stderr.Length == 0 ? stdout
                : stdout.Length == 0 ? stderr
                : stdout + "\n" + stderr;

            return new CmdResult(status, SplitLines(text), text);
        }
        catch
        {
            // adb / scrcpy 不存在、没有执行权限等：调用方按"没有输出"处理，
            // 绝不能把它包装成"设备不存在"。
            return new CmdResult(-1, Array.Empty<string>(), string.Empty);
        }
    }

    /// <summary>最多再等 3 秒；拿不到就算空输出（进程已被杀掉时管道是断的就永远不 Complete）。</summary>
    private static string AwaitText(Task<string> task)
    {
        try
        {
            return task.Wait(TimeSpan.FromSeconds(3)) ? task.Result : string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    /// <summary>与 Go 的 strings.Split(text, "\n") + Trim("\r \t") 逐行对齐。</summary>
    public static string[] SplitLines(string text)
    {
        if (text.Length == 0) return Array.Empty<string>();
        string[] raw = text.Split('\n');
        for (int i = 0; i < raw.Length; i++) raw[i] = raw[i].Trim('\r', ' ', '\t');
        return raw;
    }
}
