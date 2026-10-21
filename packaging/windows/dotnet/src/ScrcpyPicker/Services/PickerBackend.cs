using System.IO;
using System.Text.RegularExpressions;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>界面要看的运行状态（对应 Go 版 /api/status 的字段）。</summary>
public sealed record StatusInfo
{
    public string Platform { get; init; } = "windows";
    public string Adb { get; init; } = string.Empty;
    public string AdbVersion { get; init; } = string.Empty;
    public bool AdbResolved { get; init; }
    public string AdbSource { get; init; } = "none";
    public string Scrcpy { get; init; } = string.Empty;
    public string ScrcpyVersion { get; init; } = string.Empty;
    public bool ScrcpyResolved { get; init; }
    public string ScrcpySource { get; init; } = "none";
    public string ToolDir { get; init; } = string.Empty;
    public bool AdbMissing { get; init; }
    public string AdbHint { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public string LastRefresh { get; init; } = string.Empty;

    /// <summary>无线扫描的展示位：adb 可用即为开（每轮 mDNS、深度刷新加 /24 5555）。</summary>
    public bool Wireless { get; init; }
}

/// <summary>工具目录面板要看的详情（对应 Go 版 /api/toolchain）。</summary>
public sealed record ToolchainInfo
{
    public string Adb { get; init; } = string.Empty;
    public bool AdbResolved { get; init; }
    public string AdbSource { get; init; } = "none";
    public string Scrcpy { get; init; } = string.Empty;
    public bool ScrcpyResolved { get; init; }
    public string ScrcpySource { get; init; } = "none";
    public string ToolDir { get; init; } = string.Empty;
    public string ConfigToolDir { get; init; } = string.Empty;
    public string EnvToolDir { get; init; } = string.Empty;
    public string ConfigPath { get; init; } = string.Empty;
    public string ExeDir { get; init; } = string.Empty;
    public List<string> Candidates { get; init; } = new();
    public List<string> SearchRoots { get; init; } = new();
    public string Hint { get; init; } = ToolchainService.MissingHint;
}

/// <summary>投屏请求的结果。</summary>
public sealed record CastResult
{
    public string Error { get; init; } = string.Empty;
    public string Detail { get; init; } = string.Empty;
    public string Target { get; init; } = string.Empty;
    public int Pid { get; init; }
    public bool Already { get; init; }
    public string Log { get; init; } = string.Empty;
}

/// <summary>按键注入结果。</summary>
public sealed record NavResult
{
    public string Error { get; init; } = string.Empty;
    public int Sent { get; init; }
    public string Target { get; init; } = string.Empty;
    public bool Blocked { get; init; }
}

/// <summary>投屏存活状态（对应 /api/caststate）。</summary>
public sealed record CastStateInfo
{
    public int Pid { get; init; }
    public bool Running { get; init; }
    public double ElapsedSeconds { get; init; } = -1;
    public bool Ready { get; init; }
}

/// <summary>
/// 无头后端：把工具链、发现、投屏、配置这几件事按 Go 版 server.go 的语义组织起来，
/// 但不再经过 HTTP —— 界面直接调它，ViewModel 只管展示与线程调度。
///
/// 保留的一条老规矩：所有投屏/按键的"目标"都在这里按设备 Key 现算，
/// 界面上飘过来的地址一律不作为依据（原来那是防 CSRF 的挡板，现在防的是"列表和现实不一致"）。
/// </summary>
public sealed class PickerBackend
{
    /// <summary>自动搜索的时间上限，与 Go 版 scanBudget 一致。</summary>
    public static readonly TimeSpan ScanBudget = TimeSpan.FromSeconds(10);

    /// <summary>用户主动断开无线会话后的静默期，防止 mDNS 扫描下一轮又把它接回来。</summary>
    private static readonly TimeSpan WirelessDisconnectCooldown = TimeSpan.FromMinutes(10);

    /// <summary>adb 拒绝注入按键时的特征（MIUI/HyperOS 未开"USB 调试（安全设置）"）。</summary>
    private static readonly Regex InjectBlockedRe =
        new("INJECT_EVENTS|SecurityException", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private readonly string _exeDir;
    private readonly string _envDir;
    private readonly bool _allowScan;

    private readonly object _gate = new();
    private List<WebRow> _rows = new();
    private string _lastRefresh = string.Empty;
    private string _lastError = string.Empty;
    private bool _adbMissing;
    private List<string> _lastCandidates = new();

    public ToolchainHolder Tools { get; }
    public ConfigService Config { get; }
    public DiscoveryService Discovery { get; }
    public CastManager Casts { get; }

    /// <summary>文件互传（与 macOS 1.1.0 同一套契约；受理时读本后端的行快照）。</summary>
    public TransferManager Transfers { get; }

    public PickerBackend(string exeDir, string envDir, bool allowScan)
    {
        _exeDir = exeDir;
        _envDir = envDir;
        _allowScan = allowScan;

        Config = new ConfigService();
        Tools = new ToolchainHolder(ToolchainService.Resolve(BuildOptions(allowScan)));

        // 自动搜索命中就记住，下次启动直接命中，省掉那次搜索的时间。
        var snap = Tools.Get();
        if (snap.AdbSource == ToolchainService.SourceScan && Config.ToolDir().Length == 0)
        {
            Config.SetToolDir(snap.ToolDir);
        }

        lock (_gate) _adbMissing = !snap.AdbResolved;

        Discovery = new DiscoveryService(Tools, Config);
        Casts = new CastManager(Tools);
        // SnapshotRows 返回的是本后端已加锁拷贝的行，传输受理与界面看到的是同一份事实。
        Transfers = new TransferManager(Tools, Discovery, SnapshotRows);
    }

    private ResolveOptions BuildOptions(bool allowScan) => new()
    {
        ExeDir = _exeDir,
        ConfigDir = Config.ToolDir(),
        EnvDir = _envDir.Length > 0 ? _envDir : Environment.GetEnvironmentVariable("SCRCPY_TOOL_DIR") ?? string.Empty,
        AllowScan = allowScan,
        ScanBudget = ScanBudget,
    };

    /// <summary>换掉工具链快照并让下一轮刷新立刻重跑。</summary>
    private void ApplyTools(ToolchainSnapshot t)
    {
        Tools.Set(t);
        lock (_gate)
        {
            _adbMissing = !t.AdbResolved;
            _lastError = string.Empty;
        }
    }

    /// <summary>跑一次发现 + 组装界面行。阻塞（adb 调用），只在后台线程调用。</summary>
    public List<WebRow> Refresh(bool deep)
    {
        try
        {
            List<DeviceRow> inv = Discovery.Inventory(deep, allowWireless: true);
            List<WebRow> built = WebRows.Build(inv, Config);
            lock (_gate)
            {
                _rows = built;
                _lastRefresh = DateTimeOffset.UtcNow.ToString("O");
                _lastError = string.Empty;
                _adbMissing = !Tools.Get().AdbResolved;
            }
            return built;
        }
        catch (Exception ex)
        {
            lock (_gate) _lastError = ex.Message;
            return SnapshotRows();
        }
    }

    public List<WebRow> SnapshotRows()
    {
        lock (_gate) return _rows;
    }

    public StatusInfo Status()
    {
        bool missing;
        string errTxt;
        string refreshed;
        lock (_gate)
        {
            missing = _adbMissing;
            errTxt = _lastError;
            refreshed = _lastRefresh;
        }

        var t = Tools.Get();
        return new StatusInfo
        {
            Platform = "windows",
            Adb = t.AdbPath,
            AdbVersion = ToolchainService.AdbVersion(t),
            AdbResolved = t.AdbResolved,
            AdbSource = t.AdbSource,
            Scrcpy = t.ScrcpyPath,
            ScrcpyVersion = ToolchainService.ScrcpyVersion(t),
            ScrcpyResolved = t.ScrcpyResolved,
            ScrcpySource = t.ScrcpySource,
            ToolDir = t.ToolDir,
            AdbMissing = missing,
            AdbHint = missing ? ToolchainService.MissingHint : string.Empty,
            Error = errTxt,
            LastRefresh = refreshed,
            // Windows 默认开启无线扫描：每次刷新读 mDNS，深度刷新再扫 /24 的 5555。
            // adb 都找不到时扫描无从谈起，状态行如实显示关闭。
            Wireless = t.AdbResolved,
        };
    }

    public ToolchainInfo ToolchainState()
    {
        var t = Tools.Get();
        List<string> cands;
        lock (_gate) cands = new List<string>(_lastCandidates);

        return new ToolchainInfo
        {
            Adb = t.AdbPath,
            AdbResolved = t.AdbResolved,
            AdbSource = t.AdbSource,
            Scrcpy = t.ScrcpyPath,
            ScrcpyResolved = t.ScrcpyResolved,
            ScrcpySource = t.ScrcpySource,
            ToolDir = t.ToolDir,
            ConfigToolDir = Config.ToolDir(),
            EnvToolDir = Environment.GetEnvironmentVariable("SCRCPY_TOOL_DIR") ?? string.Empty,
            ConfigPath = Config.FilePath,
            ExeDir = _exeDir,
            Candidates = cands,
            SearchRoots = ToolchainService.SearchRoots(),
        };
    }

    /// <summary>跑一次自动搜索，把候选留在内存里供界面点选。</summary>
    public List<string> ScanToolchain()
    {
        List<string> hits = ToolchainService.ScanFor(ScanBudget);
        lock (_gate) _lastCandidates = hits;
        return hits;
    }

    /// <summary>
    /// 指定 / 清除工具目录。dir 为空串表示清除记住的目录（回到纯自动查找）。
    /// 返回值第一项是错误信息（空表示成功）。
    /// </summary>
    public (string Error, ToolchainSnapshot Result) ApplyToolDir(string dir)
    {
        dir = (dir ?? string.Empty).Trim();
        if (dir.Length == 0)
        {
            Config.SetToolDir(string.Empty);
            var back = ToolchainService.Resolve(BuildOptions(true));
            ApplyTools(back);
            return (string.Empty, back);
        }

        if (!Directory.Exists(dir))
            return ("目录不存在：" + dir, Tools.Get());
        if (!ToolchainService.HasAdb(dir))
            return ("这个目录下没有找到 adb（Windows 上应为 adb.exe）：" + dir, Tools.Get());

        Config.SetToolDir(dir);
        var fresh = ToolchainService.Resolve(BuildOptions(false));
        ApplyTools(fresh);
        if (!fresh.AdbResolved)
            return ("已保存目录，但重新解析后仍没找到 adb", fresh);
        return (string.Empty, fresh);
    }

    private WebRow? FindLiveRow(string key) =>
        SnapshotRows().FirstOrDefault(r => r.Key == key && !r.Offline);

    /// <summary>启动投屏（对应 /api/cast）。同一台设备只保留一个窗口。</summary>
    public CastResult StartCast(string key, string mode, bool noClip, bool force)
    {
        var row = FindLiveRow(key);
        if (row is null)
            return new CastResult { Error = "device has no reachable transport" };

        string target = mode switch
        {
            "usb" when row.Usb => Discovery.ResolveTarget(key, string.Empty, row.UsbSerial, string.Empty, string.Empty),
            "tls" when row.Tls.Length > 0 => Discovery.ResolveTarget(key, string.Empty, string.Empty, row.Tls, string.Empty),
            "tcp" when row.Tcp5555.Length > 0 => Discovery.ResolveTarget(key, string.Empty, string.Empty, string.Empty, row.Tcp5555),
            _ => Discovery.ResolveTarget(key, row.Preferred, row.UsbSerial, row.Tls, row.Tcp5555),
        };
        if (target.Length == 0)
            return new CastResult { Error = "device has no reachable transport" };

        int existing = Casts.State(key)?.Pid ?? 0;
        if (existing == 0 || !Casts.IsAlive(existing))
        {
            int adopted = Casts.Adopt(key, target);
            if (adopted > 0) existing = adopted;
            else Casts.Clear(key);
        }

        if (existing != 0 && !force)
            return new CastResult { Pid = existing, Target = target, Already = true };

        if (existing != 0)
        {
            Casts.Kill(existing);
            Thread.Sleep(400);
            Casts.Clear(key);
        }

        var tc = Tools.Get();
        if (!tc.ScrcpyResolved)
        {
            Casts.Clear(key);
            return new CastResult
            {
                Error = "scrcpy_exited",
                Detail = "无法启动 scrcpy（未找到可执行文件？）",
                Target = target,
            };
        }

        (int pid, string logPath) = Casts.Start(key, target, noClip);
        if (pid == 0)
        {
            Casts.Clear(key);
            return new CastResult
            {
                Error = "scrcpy_exited",
                Detail = "无法启动 scrcpy（未找到可执行文件？）",
                Target = target,
            };
        }

        // 给 scrcpy 一点时间：目标不可用时它会立刻带着报错退出。
        Thread.Sleep(1500);
        if (Casts.IsAlive(pid))
            return new CastResult { Pid = pid, Target = target, Log = logPath };

        string detail = Casts.LogSummary(logPath);
        Casts.Clear(key);
        return new CastResult
        {
            Error = "scrcpy_exited",
            Detail = detail.Length > 0 ? detail : "scrcpy 启动后立即退出",
            Target = target,
            Pid = pid,
        };
    }

    public CastStateInfo CastState(string key)
    {
        var st = Casts.State(key);
        bool alive = false;
        double elapsed = -1;
        bool ready = false;
        if (st is not null)
        {
            alive = Casts.IsAlive(st.Pid);
            if (!alive) Casts.Clear(key);
            elapsed = (DateTimeOffset.Now - st.Started).TotalSeconds;
            ready = st.LogPath.Length > 0 && Casts.IsReady(st.LogPath);
        }
        return new CastStateInfo { Pid = st?.Pid ?? 0, Running = alive, ElapsedSeconds = elapsed, Ready = ready };
    }

    /// <summary>发送一个 Android keyevent（对应 /api/nav）。code 范围与旧版一致。</summary>
    public NavResult SendNav(string key, int code)
    {
        var row = FindLiveRow(key);
        if (row is null) return new NavResult { Error = "no live target for device" };

        string target = Discovery.ResolveTarget(key, row.Preferred, row.UsbSerial, row.Tls, row.Tcp5555);
        if (target.Length == 0) return new NavResult { Error = "no live target for device" };
        if (code < 1 || code > 500) return new NavResult { Error = "bad keyevent code" };

        string outText = ToolchainService.AdbText(Tools.Get(),
            new[] { "-s", target, "shell", "input", "keyevent", code.ToString() });

        if (InjectBlockedRe.IsMatch(outText))
            return new NavResult { Error = "input_inject_blocked", Sent = code, Target = target, Blocked = true };

        return new NavResult { Sent = code, Target = target };
    }

    /// <summary>设备上的杂项操作（对应 /api/action：alias / forget / disconnect）。</summary>
    public bool RunAction(string key, string op, string? alias = null)
    {
        switch (op)
        {
            case "alias":
                DeviceCache c = Config.Device(key);
                var next = c with
                {
                    Alias = alias ?? string.Empty,
                    Ts = c.Ts.Length > 0 ? c.Ts : DateTimeOffset.UtcNow.ToString("O"),
                };
                Config.SetDevice(key, next);
                return true;
            case "forget":
                Config.RemoveDevice(key);
                return true;
            case "disconnect":
                var row = SnapshotRows().FirstOrDefault(r => r.Key == key);
                if (row is not null)
                {
                    // 「断开无线会话」只针对无线端点；不能拿 Preferred 去猜 —— USB 优先时
                    // Preferred 是 USB 串号，Disconnect 会因不含冒号而静默不动。
                    var endpoints = new List<string>();
                    if (row.Tls.Contains(':')) endpoints.Add(row.Tls);
                    if (row.Tcp5555.Contains(':') && !endpoints.Contains(row.Tcp5555))
                        endpoints.Add(row.Tcp5555);

                    foreach (string endpoint in endpoints)
                    {
                        Discovery.Disconnect(endpoint);
                        // 自动扫描是默认开着的：不设静默期的话，下一轮刷新就会把它接回来。
                        Discovery.SuppressWireless(endpoint, WirelessDisconnectCooldown);
                    }
                }
                return true;
            default:
                return false;
        }
    }

    /// <summary>USB 优先开关（对应旧版界面没有的入口，这里给界面用）。</summary>
    public void SetPreferUsb(bool value)
    {
        Config.SetPreferUsb(value);
    }

    /// <summary>读回落盘的 USB 优先状态：界面一打开就该显示真实的开关位置。</summary>
    public bool PreferUsb => Config.Settings().PreferUsb;

    /// <summary>导航条开关（吸附式导航条是否随投屏出现）。</summary>
    public void SetNavBarOn(bool value)
    {
        Config.SetNavBar(value);
    }

    public bool NavBarOn => Config.Settings().NavBar;
}
