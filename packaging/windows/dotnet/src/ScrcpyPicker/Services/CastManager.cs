using System.Diagnostics;
using System.IO;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>一次投屏的状态（对应 Go 的 cast.CastState）。</summary>
public sealed class CastState
{
    public int Pid { get; set; }
    public DateTimeOffset Started { get; set; }
    public string LogPath { get; set; } = string.Empty;
}

/// <summary>
/// scrcpy 进程的启动、复用与存活判定（移植自 Go 版 internal/cast）。
///
/// 两条从旧版血泪里留下来的规矩：
///   * 记录的 PID 只有在"进程还在 **且** 映像仍是 scrcpy"时才算在投屏中——
///     光看进程存在会误收一个被回收后重新分配给别的程序的 PID；
///   * "进程起来了"≠"正在投屏"，窗口真出现要以 scrcpy 自己写的日志为准。
/// </summary>
public sealed class CastManager
{
    private static readonly string[] ReadyPatterns =
    {
        @"\[server\] INFO: Device:", "New texture", "Renderer:", @"scrcpy \d",
    };

    private readonly object _gate = new();
    private readonly Dictionary<string, CastState> _proc = new();
    private readonly ToolchainHolder _tools;

    public CastManager(ToolchainHolder tools) => _tools = tools;

    private ToolchainSnapshot Tc() => _tools.Get();

    /// <summary>
    /// 构造 scrcpy 启动参数。--shortcut-mod 显式写出，保证 Alt+B / Alt+H / Alt+S
    /// 在镜像窗口里可用（不写的话 scrcpy 5.0 的默认修饰键会换）。
    /// </summary>
    public static List<string> ArgList(string target, bool noClipboard)
    {
        var a = new List<string>
        {
            "-s", target, "-m", "1280", "-b", "4M", "--max-fps=60",
            "--window-title", target, "--shortcut-mod=lalt,lsuper",
        };
        if (noClipboard) a.Add("--no-clipboard-autosync");
        return a;
    }

    /// <summary>启动 scrcpy，stdout/stderr 落到临时文件，用于判断"已连上"和解释失败原因。</summary>
    public (int Pid, string LogPath) Start(string key, string target, bool noClipboard)
    {
        string logPath = Path.Combine(Path.GetTempPath(),
            $"scrcpy-picker-cast-{Guid.NewGuid().ToString("N")[..8]}.err");
        string outPath = logPath + ".out";

        var tc = Tc();
        if (tc.ScrcpyPath.Length == 0 || !File.Exists(tc.ScrcpyPath)) return (0, logPath);

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = tc.ScrcpyPath,
                // 工作目录用 scrcpy.exe 自己所在目录：它要在旁边找 scrcpy-server 与依赖 dll。
                WorkingDirectory = tc.WorkDir,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (string arg in ArgList(target, noClipboard)) psi.ArgumentList.Add(arg);

            var p = new Process { StartInfo = psi };
            var errSb = new StringBuilder();
            var outSb = new StringBuilder();
            p.ErrorDataReceived += (_, e) => { if (e.Data is not null) { lock (errSb) errSb.AppendLine(e.Data); } };
            p.OutputDataReceived += (_, e) => { if (e.Data is not null) { lock (outSb) outSb.AppendLine(e.Data); } };

            try
            {
                if (!p.Start())
                {
                    p.Dispose();
                    return (0, logPath);
                }
            }
            catch
            {
                p.Dispose();
                return (0, logPath);
            }
            p.BeginErrorReadLine();
            p.BeginOutputReadLine();
            int pid = p.Id;

            lock (_gate)
            {
                _proc[key] = new CastState { Pid = pid, Started = DateTimeOffset.Now, LogPath = logPath };
            }

            // 后台回收：等 scrcpy 自己退出并把日志落全，再释放 Process 对象。
            // 不能在这里 using —— 句柄一释放，WaitForExitAsync 就拿不到退出事件了。
            // scrcpy 退出后它自己就没了，我们不接管窗口，只做"这台设备还在不在投屏"的判据。
            _ = Task.Run(async () =>
            {
                try
                {
                    await p.WaitForExitAsync();
                }
                catch { /* 进程已被 Kill 掉也走到这里 */ }
                FlushLogs(logPath, outPath, errSb, outSb);
                try { p.Dispose(); } catch { /* 忽略 */ }
            });

            FlushLogs(logPath, outPath, errSb, outSb); // 先建出空文件，IsReady 才不会因"文件不存在"而一直假
            return (pid, logPath);
        }
        catch
        {
            return (0, logPath);
        }
    }

    private static void FlushLogs(string logPath, string outPath, StringBuilder errSb, StringBuilder outSb)
    {
        try
        {
            string err, outText;
            lock (errSb) err = errSb.ToString();
            lock (outSb) outText = outSb.ToString();
            File.WriteAllText(logPath, err);
            File.WriteAllText(outPath, outText);
        }
        catch
        {
            // 日志写不下不影响投屏本身
        }
    }

    /// <summary>PID 是否仍然是一个活着的 scrcpy.exe。</summary>
    public bool IsAlive(int pid) => IsScrcpyProcess(pid);

    /// <summary>
    /// 认领上一轮遗留的投屏窗口：程序可以退出再启动，而 scrcpy 还活着，
    /// 同一台设备再开一个 scrcpy 会和旧的抢设备。
    /// </summary>
    public int Adopt(string key, string target)
    {
        int pid = FindPidByTarget(target);
        if (pid <= 0) return 0;
        lock (_gate)
        {
            _proc[key] = new CastState { Pid = pid, Started = DateTimeOffset.Now, LogPath = string.Empty };
        }
        return pid;
    }

    public CastState? State(string key)
    {
        lock (_gate) return _proc.TryGetValue(key, out var s) ? s : null;
    }

    public void Clear(string key)
    {
        lock (_gate) _proc.Remove(key);
    }

    /// <summary>结束一个 scrcpy 进程（TerminateProcess 已是强杀，与 Go 版一致）。</summary>
    public void Kill(int pid) => KillProcess(pid);

    /// <summary>scrcpy 是否已经连上设备、窗口马上就到。</summary>
    public bool IsReady(string logPath)
    {
        if (logPath.Length == 0) return false;
        string txt = ReadLog(logPath);
        if (txt.Length == 0) return false;
        foreach (string pat in ReadyPatterns)
        {
            try
            {
                if (Regex.IsMatch(txt, pat, RegexOptions.CultureInvariant)) return true;
            }
            catch
            {
                if (txt.Contains(pat, StringComparison.Ordinal)) return true;
            }
        }
        return false;
    }

    /// <summary>失败时给用户看的一行摘要（前 8 行非空输出，空白折叠）。</summary>
    public string LogSummary(string logPath)
    {
        if (logPath.Length == 0) return string.Empty;
        string txt = ReadLog(logPath);
        var lines = txt.Split('\n')
            .Select(l => l.Trim('\r', ' ', '\t'))
            .Where(l => l.Length > 0)
            .Take(8)
            .ToList();
        return string.Join(" ", lines);
    }

    private static string ReadLog(string logPath)
    {
        string err = string.Empty, outText = string.Empty;
        try { if (File.Exists(logPath)) err = File.ReadAllText(logPath); } catch { }
        try { if (File.Exists(logPath + ".out")) outText = File.ReadAllText(logPath + ".out"); } catch { }
        return err + "\n" + outText;
    }

    /// <summary>进程存在且映像名以 scrcpy 结尾才算数（PID 会被回收复用）。</summary>
    private static bool IsScrcpyProcess(int pid)
    {
        if (pid <= 0) return false;
        IntPtr h = Kernel32.OpenProcess(Kernel32.ProcessQueryLimitedInformation, false, (uint)pid);
        if (h == IntPtr.Zero) return false;
        try
        {
            if (!Kernel32.GetExitCodeProcess(h, out uint code) || code != Kernel32.StillActive) return false;

            var sb = new StringBuilder(260);
            uint size = 260;
            if (!Kernel32.QueryFullProcessImageName(h, 0, sb, ref size)) return false;
            string img = sb.ToString(0, (int)size);
            string head = img.ToLowerInvariant();
            if (head.EndsWith(".exe", StringComparison.Ordinal)) head = head[..^4];
            return head.EndsWith("scrcpy", StringComparison.Ordinal);
        }
        finally
        {
            Kernel32.CloseHandle(h);
        }
    }

    /// <summary>
    /// 在跑着的 scrcpy.exe 里找命令行包含 target 的那个 PID。
    /// Go 版是起一个 powershell 查 CIM，这里直接用 System.Management，
    /// 少起一个进程、也不受本机执行策略影响；查不到就返回 0（调用方会当"没有可认领的窗口"）。
    /// </summary>
    private static int FindPidByTarget(string target)
    {
        if (target.Length == 0) return 0;
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='scrcpy.exe'");
            foreach (ManagementObject mo in searcher.Get())
            {
                string? cmd = mo["CommandLine"] as string;
                if (cmd is null) continue;
                if (cmd.Contains(target, StringComparison.Ordinal) &&
                    mo["ProcessId"] is uint pid && pid > 0)
                {
                    return (int)pid;
                }
            }
        }
        catch
        {
            // WMI 服务不可用时退回"只看进程名"，此时无法区分目标，宁可不认领。
        }
        return 0;
    }

    private static void KillProcess(int pid)
    {
        if (pid <= 0) return;
        IntPtr h = Kernel32.OpenProcess(Kernel32.ProcessTerminate, false, (uint)pid);
        if (h == IntPtr.Zero) return;
        try
        {
            Kernel32.TerminateProcess(h, 1);
        }
        finally
        {
            Kernel32.CloseHandle(h);
        }
    }
}
