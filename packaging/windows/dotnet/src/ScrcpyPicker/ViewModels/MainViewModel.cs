using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.ViewModels;

/// <summary>界面刷新节奏，与旧前端 POLL_MS 一致。</summary>
public static class Cadence
{
    public const int PollMs = 10000;
    public const int CastWindowLimitMs = 20000;
    public const int CastFallbackMs = 6000;
    public const int CastPollMs = 400;
}

/// <summary>
/// 主窗口视图模型（MVVM 的 VM）。
///
/// 分工：所有事实判断都在 <see cref="PickerBackend"/>（服务层，可无头单测），
/// 这里只做三件事——把结果搬到 UI 线程、把状态摆成界面要绑的属性、
/// 把用户动作转成对服务层的调用。后台 adb 调用一律丢到线程池，
/// 绝不占用 UI 线程（ProcessRunner 是同步阻塞的，这是硬约束）。
/// </summary>
public sealed partial class MainViewModel : ObservableObject
{
    private readonly PickerBackend _backend;
    private readonly System.Windows.Threading.DispatcherTimer _timer;

    /// <summary>导航条管家；服务层不依赖 WPF 窗口，所以只在界面起来后才建。</summary>
    private readonly NavBarService? _navs;

    /// <summary>正在启动投屏的设备 Key（列表重绘时要保持行内状态）。</summary>
    private readonly HashSet<string> _casting = new();

    /// <summary>同一时刻只允许一次刷新与一次投屏启动，和旧前端的两把锁一致。</summary>
    private bool _refreshing;
    private bool _castBusy;

    public MainViewModel(PickerBackend backend)
    {
        _backend = backend;
        Devices = new ObservableCollection<DeviceItem>();
        ToolCandidates = new ObservableCollection<string>();
        // 开关位置以落盘的配置为准，不能凭默认值画。
        preferUsb = backend.PreferUsb;
        navBarOn = backend.NavBarOn;

        // 文件互传：服务层回调在后台线程，TransferCenter 负责切回 UI 线程。
        Transfer = new TransferCenter(backend.Transfers, ResolveDeviceName,
            System.Windows.Application.Current.Dispatcher);
        Transfer.DeviceTransferStateChanged += OnTransferStateChanged;

        _navs = new NavBarService(SendKeyByKey, msg => Toast("ok", msg, string.Empty, 2600),
            pid => _backend.Casts.IsAlive(pid));
        _navs.Enabled = NavBarOn;

        _timer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(Cadence.PollMs),
        };
        // DispatcherTimer 不 Start() 就永远不 Tick —— 这是踩过一次的老坑。
        _timer.Tick += async (_, _) => await RefreshAsync(deep: false);
        _timer.Start();

        _ = RefreshAsync(deep: false);
    }

    [ObservableProperty]
    private ObservableCollection<DeviceItem> devices;

    /// <summary>文件互传的卡片区与命令入口（XAML 绑定 Transfer.*）。</summary>
    public TransferCenter Transfer { get; }

    [ObservableProperty]
    private string bannerText = string.Empty;

    [ObservableProperty]
    private bool bannerVisible;

    [ObservableProperty]
    private bool toolPanelVisible;

    [ObservableProperty]
    private string toolDirInput = string.Empty;

    [ObservableProperty]
    private string toolNote = string.Empty;

    [ObservableProperty]
    private ObservableCollection<string> toolCandidates;

    [ObservableProperty]
    private bool toolBusy;

    [ObservableProperty]
    private string footerText = "加载中…";

    [ObservableProperty]
    private string wirelessText = "无线/扫描：关闭";

    [ObservableProperty]
    private string toastTitle = string.Empty;

    [ObservableProperty]
    private string toastSub = string.Empty;

    /// <summary>空=进行中 / ok / err / warn。</summary>
    [ObservableProperty]
    private string toastState = string.Empty;

    [ObservableProperty]
    private bool toastVisible;

    /// <summary>
    /// 提示卡片左侧符号：成功 ✓，进行中 …，其余状态 !。
    /// 旧前端用的是「spinner + 文字」两层，这里一个字符足够表达"没坏、还在等"。
    /// </summary>
    public string ToastGlyph => ToastState switch
    {
        "ok" => "✓",
        "" => "…",
        _ => "!",
    };

    partial void OnToastStateChanged(string value) => OnPropertyChanged(nameof(ToastGlyph));

    [ObservableProperty]
    private bool preferUsb = true;

    /// <summary>导航条总开关（落盘）。关掉时条子收起，投屏本身不受影响。</summary>
    [ObservableProperty]
    private bool navBarOn = true;

    partial void OnNavBarOnChanged(bool value)
    {
        if (_navs is not null) _navs.Enabled = value;
    }

    [RelayCommand]
    private void ToggleNavBar()
    {
        // 只落盘：收起/放出由 OnNavBarOnChanged → NavBarService.Enabled 负责，
        // 这里不销毁条子，否则用户把开关拨回来时要等下一次投屏才又出现。
        _backend.SetNavBarOn(NavBarOn);
    }

    /// <summary>当前挂着导航条的设备数（冒烟测试要看的钩子）。</summary>
    public int NavBarCount => _navs?.Count ?? 0;

    public string ScanButtonText => ToolBusy ? "搜索中…" : "自动搜索";

    partial void OnToolBusyChanged(bool value) => OnPropertyChanged(nameof(ScanButtonText));

    public string StatusLine
    {
        get
        {
            var s = _backend.Status();
            string adb = s.AdbResolved ? $"{Path.GetFileName(s.Adb)}（{ToolchainService.SourceLabel(s.AdbSource)}）" : "未找到";
            string scrcpy = s.ScrcpyResolved ? $"{Path.GetFileName(s.Scrcpy)}（{ToolchainService.SourceLabel(s.ScrcpySource)}）" : "未找到";
            return $"adb：{adb}　·　scrcpy：{scrcpy}";
        }
    }

    // ---- 刷新 ----

    /// <summary>拉一次设备清单 + 状态。耗时调用全在任务线程上跑。</summary>
    public async Task RefreshAsync(bool deep)
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            List<WebRow> rows = await Task.Run(() => _backend.Refresh(deep));
            StatusInfo st = await Task.Run(_backend.Status);
            ApplyRows(rows, st);
            ApplyStatus(st);
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void ApplyRows(List<WebRow> rows, StatusInfo st)
    {
        Devices = new ObservableCollection<DeviceItem>(
            rows.Select(r => new DeviceItem(
                r, _casting.Contains(r.Key), Transfer.IsTransferring(r.Key))));

        string whenText = "—";
        if (DateTimeOffset.TryParse(st.LastRefresh, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out var when))
        {
            whenText = when.ToLocalTime().ToString("HH:mm:ss");
        }
        FooterText = $"共 {rows.Count} 台 · 上次刷新 {whenText}";
        OnPropertyChanged(nameof(StatusLine));
    }

    private void ApplyStatus(StatusInfo st)
    {
        WirelessText = st.Wireless ? "无线/扫描：开启" : "无线/扫描：关闭";

        if (st.AdbMissing)
        {
            ShowBanner(st.AdbHint.Length > 0 ? st.AdbHint : ToolchainService.MissingHint);
            OpenToolPanel(st.ToolDir);
        }
        else if (!st.ScrcpyResolved)
        {
            ShowBanner("adb 已找到，但没找到 scrcpy：投屏会失败。请把 scrcpy.exe 及其 dll 与 adb.exe 放进同一个目录，或在下方指定该目录。");
            OpenToolPanel(st.ToolDir);
        }
        else if (st.Error.Length > 0)
        {
            ShowBanner("后端错误：" + st.Error);
            ToolPanelVisible = false;
        }
        else
        {
            HideBanner();
            ToolPanelVisible = false;
        }
    }

    [RelayCommand]
    private Task Refresh() => RefreshAsync(deep: false);

    [RelayCommand]
    private Task DeepRefresh() => RefreshAsync(deep: true);

    // ---- 工具目录面板 ----

    private void ShowBanner(string text)
    {
        BannerText = text;
        BannerVisible = true;
    }

    private void HideBanner()
    {
        BannerVisible = false;
        BannerText = string.Empty;
    }

    private void OpenToolPanel(string dir)
    {
        ToolPanelVisible = true;
        // 只在用户没自己动过输入框时回填，避免 10 秒轮询把人正在打的字抹掉。
        if (dir.Length > 0 && ToolDirInput.Length == 0) ToolDirInput = dir;
        _ = LoadToolInfoAsync();
    }

    private async Task LoadToolInfoAsync()
    {
        ToolchainInfo info = await Task.Run(_backend.ToolchainState);
        var bits = new List<string>
        {
            "当前 adb：" + (info.AdbResolved ? info.Adb + "（" + ToolchainService.SourceLabel(info.AdbSource) + "）" : "未找到"),
            "当前 scrcpy：" + (info.ScrcpyResolved ? info.Scrcpy + "（" + ToolchainService.SourceLabel(info.ScrcpySource) + "）" : "未找到"),
        };
        if (info.ConfigToolDir.Length > 0) bits.Add("已记住：" + info.ConfigToolDir);
        if (info.EnvToolDir.Length > 0) bits.Add("SCRCPY_TOOL_DIR：" + info.EnvToolDir);
        if (info.ConfigPath.Length > 0) bits.Add("配置写在 " + info.ConfigPath);
        ToolNote = string.Join("　·　", bits);

        ToolCandidates = new ObservableCollection<string>(info.Candidates);
    }

    [RelayCommand]
    private async Task ScanToolchain()
    {
        if (ToolBusy) return;
        ToolBusy = true;
        ToolNote = "正在本机搜索 adb.exe（只看固定盘，最多 10 秒）…";
        try
        {
            List<string> hits = await Task.Run(_backend.ScanToolchain);
            if (hits.Count == 0)
            {
                ToolNote = "没搜到含 adb.exe 的目录。可以把 adb.exe / AdbWinApi.dll / AdbWinUsbApi.dll / scrcpy.exe " +
                           "放到 exe 旁边的 tools 目录，或手工填一个已有目录再点「保存并应用」。";
                ToolCandidates = new ObservableCollection<string>();
            }
            else
            {
                ToolNote = $"搜到 {hits.Count} 个候选目录，点一下即应用：";
                ToolCandidates = new ObservableCollection<string>(hits);
            }
        }
        finally
        {
            ToolBusy = false;
        }
    }

    /// <summary>
    /// 应用一个工具目录。<paramref name="dir"/> 为 null 时取输入框内容；
    /// 传空串（清除按钮）走 <see cref="ClearToolDir"/>，不会在这里被"先填一个目录"拦掉。
    /// </summary>
    [RelayCommand]
    private Task ApplyToolDir(string? dir) =>
        ApplyToolDirAsyncInternal(dir ?? ToolDirInput, requireNonEmpty: true);

    [RelayCommand]
    private Task ClearToolDir() => ApplyToolDirAsyncInternal(string.Empty, requireNonEmpty: false);

    private async Task ApplyToolDirAsyncInternal(string? raw, bool requireNonEmpty)
    {
        string target = (raw ?? string.Empty).Trim();
        if (requireNonEmpty && target.Length == 0)
        {
            ShowBanner("先填一个含 adb.exe 的目录，或点「自动搜索」让程序在本机找。");
            return;
        }
        if (ToolBusy) return;

        ToolBusy = true;
        try
        {
            (string error, ToolchainSnapshot result) = await Task.Run(() => _backend.ApplyToolDir(target));
            if (error.Length > 0)
            {
                ShowBanner("设置失败：" + error);
                await LoadToolInfoAsync();
                return;
            }

            if (target.Length > 0)
            {
                ToolDirInput = target;
                Toast("ok", "已应用工具目录", result.AdbPath, 4000);
            }
            else
            {
                ToolDirInput = string.Empty;
                Toast("ok", "已清除记住的目录", "下次刷新回到自动查找", 4000);
            }
            await RefreshAsync(deep: false);
        }
        finally
        {
            ToolBusy = false;
        }
    }

    // ---- 投屏 ----

    /// <summary>
    /// 启动投屏。返回后还要等窗口真出现（scrcpy 拉起进程到建窗要 1~3 秒：
    /// 推 server、握手、开 SDL 窗口），所以继续轮询一次状态，把"还在等"如实显示出来。
    /// </summary>
    [RelayCommand]
    private async Task CastAsync(DeviceItem? item)
    {
        if (item is null) return;
        await CastCore(item, mode: "auto", noClip: false, force: false);
    }

    private async Task CastCore(DeviceItem item, string mode, bool noClip, bool force)
    {
        string key = item.Key;
        string name = item.Name;

        if (_casting.Contains(key))
        {
            Toast("warn", "这台设备正在启动投屏…", name + " · 请稍候", 3000);
            return;
        }
        if (_castBusy)
        {
            Toast("warn", "正在启动另一台设备的投屏…", "稍等一下再点 " + name, 3000);
            return;
        }

        _castBusy = true;
        _casting.Add(key);
        MarkCasting(key, true);
        HideBanner();
        Toast("", "正在启动投屏…", name + " · 正在连接设备", 0);

        try
        {
            CastResult r = await Task.Run(() => _backend.StartCast(key, mode, noClip, force));

            if (r.Error == "scrcpy_exited")
            {
                string why = r.Detail.Trim();
                ShowBanner("投屏启动失败" + (r.Target.Length > 0 ? $"（目标 {r.Target}）" : "") + "：" +
                    (why.Length > 0 ? why : "scrcpy 启动后立即退出") + " —— 可试试右键「强制重新投屏」。");
                Toast("err", "投屏启动失败", why.Length > 0 ? why : "scrcpy 启动后立即退出", 8000);
                return;
            }
            if (r.Error == "device has no reachable transport")
            {
                ShowBanner("找不到这台设备的可用通道：adb 当前没列出它。插上 USB、或点「深度刷新」重新发现后再投屏。");
                Toast("err", "没有可用通道", name + " · adb 当前没列出这台设备", 6000);
                return;
            }
            if (r.Error.Length > 0)
            {
                ShowBanner("投屏失败：" + r.Error);
                Toast("err", "投屏失败", r.Error, 6000);
                return;
            }
            if (r.Already)
            {
                ShowBanner("该设备已在投屏中，已复用现有窗口（关掉旧窗口后可再次投屏，或用右键「强制重新投屏」）。");
                Toast("ok", "已复用现有投屏窗口", name, 2600);
                AttachNavBar(key, name, r.Pid);
                return;
            }

            bool? up = await WaitForWindowAsync(key, name);
            if (up == false)
            {
                ShowBanner("投屏进程启动后中途退出，请用右键「强制重新投屏」再试一次。");
                Toast("err", "投屏进程已退出", name + " · 可试「强制重新投屏」", 8000);
            }
            else if (up == null)
            {
                Toast("warn", "投屏还在启动中", name + " · 若一直没窗口，试试「强制重新投屏」", 6000);
                AttachNavBar(key, name, r.Pid);
            }
            else
            {
                HideBanner();
                Toast("ok", "投屏窗口已打开", name, 2200);
                AttachNavBar(key, name, r.Pid);
            }
        }
        finally
        {
            _casting.Remove(key);
            _castBusy = false;
            MarkCasting(key, false);
        }
    }

    /// <summary>true=窗口已就绪 / false=进程中途退出 / null=还在启动（超时不算失败）。</summary>
    private async Task<bool?> WaitForWindowAsync(string key, string name)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < Cadence.CastWindowLimitMs)
        {
            CastStateInfo st = await Task.Run(() => _backend.CastState(key));
            if (!st.Running) return false;                        // 进程中途退出了
            if (st.Ready) return true;                            // scrcpy 已连上设备
            if (st.ElapsedSeconds < 0 || st.ElapsedSeconds * 1000 >= Cadence.CastFallbackMs)
                return true;                                      // 认领的孤儿 / 兜底
            Toast("", "正在启动投屏…",
                $"{name} · 已等待 {sw.Elapsed.TotalSeconds:0.0}s", 0);
            await Task.Delay(Cadence.CastPollMs);
        }
        return null;
    }

    private void MarkCasting(string key, bool on)
    {
        if (on) _casting.Add(key);
        else _casting.Remove(key);
        var item = Devices.FirstOrDefault(d => d.Key == key);
        if (item is not null) item.IsCasting = on;
    }

    /// <summary>TransferCenter 已切到 UI 线程；列表重绘后仍按 Key 贴回「传输中」。</summary>
    private void OnTransferStateChanged(string key, bool active)
    {
        var item = Devices.FirstOrDefault(d => d.Key == key);
        if (item is not null) item.IsTransferring = active;
    }

    /// <summary>显示名：先用界面行，再退回服务层快照，最后兜底 Key。</summary>
    private string ResolveDeviceName(string key)
    {
        string fromRows = Devices.FirstOrDefault(d => d.Key == key)?.Name ?? string.Empty;
        if (fromRows.Length > 0) return fromRows;
        string fromBackend = _backend.SnapshotRows()
            .FirstOrDefault(r => r.Key == key)?.Name ?? string.Empty;
        return fromBackend.Length > 0 ? fromBackend : key;
    }

    /// <summary>
    /// 投屏起来后挂上导航条。开关关着就不挂；pid 为 0（没起来）也不挂。
    /// 注意本版没有托盘：主窗口关掉就是进程退出，导航条跟着收。
    /// </summary>
    private void AttachNavBar(string key, string name, int pid)
    {
        if (!NavBarOn || pid <= 0) return;
        _navs?.Ensure(key, name, pid);
    }

    // ---- 按键 / 右键菜单动作 ----

    /// <summary>Android keyevent 码：菜单那四个与旧前端一致，导航条另加音量/息屏。</summary>
    public const int KeyWake = 224, KeyBack = 4, KeyHome = 3, KeyOverview = 187,
                     KeyVolDown = 25, KeyVolUp = 24, KeySleep = 223;

    /// <summary>
    /// 视图要弹的对话框不发生在服务层：这里只把"请用户输入"的意图发出去，
    /// 由 MainWindow 的 code-behind 负责对话框与结果回传（MVVM 里对话框属于 View）。
    /// </summary>
    public event Action<DeviceItem>? AliasRequested;

    public event Action<DeviceItem>? ForgetRequested;

    private async Task SendKeyCore(DeviceItem? item, int code)
    {
        if (item is null) return;
        await SendKeyByKey(item.Key, code);
    }

    /// <summary>
    /// 按 Key 发一个键。右键菜单和导航条共用这一条路径，
    /// 所以 MIUI 拒绝注入时的提示文案两端一致（导航条点错了也能知道为什么没反应）。
    /// </summary>
    private async Task SendKeyByKey(string key, int code)
    {
        if (key.Length == 0) return;
        NavResult r = await Task.Run(() => _backend.SendNav(key, code));
        if (r.Error == "input_inject_blocked")
        {
            ShowBanner("该设备拒绝了按键注入。小米/MIUI/HyperOS 需在「开发者选项」中额外开启" +
                "「USB 调试（安全设置）」（可能要求登录小米账号并插入 SIM 卡）；开启后 返回/桌面/多任务/唤醒 即可生效。");
        }
        else if (r.Error.Length > 0)
        {
            ShowBanner("按键发送失败：" + r.Error);
        }
        else
        {
            HideBanner();
        }
    }

    [RelayCommand] private Task WakeScreen(DeviceItem? item) => SendKeyCore(item, KeyWake);
    [RelayCommand] private Task SendBack(DeviceItem? item) => SendKeyCore(item, KeyBack);
    [RelayCommand] private Task SendHome(DeviceItem? item) => SendKeyCore(item, KeyHome);
    [RelayCommand] private Task SendOverview(DeviceItem? item) => SendKeyCore(item, KeyOverview);

    [RelayCommand] private Task CastUsb(DeviceItem? item) => item is null ? Task.CompletedTask : CastCore(item, "usb", false, false);
    [RelayCommand] private Task CastNoClip(DeviceItem? item) => item is null ? Task.CompletedTask : CastCore(item, "auto", true, false);
    [RelayCommand] private Task CastForce(DeviceItem? item) => item is null ? Task.CompletedTask : CastCore(item, "auto", false, true);

    [RelayCommand]
    private void RequestAlias(DeviceItem? item)
    {
        if (item is not null) AliasRequested?.Invoke(item);
    }

    [RelayCommand]
    private Task DisconnectDevice(DeviceItem? item) =>
        item is null ? Task.CompletedTask : Disconnect(item.Key);

    [RelayCommand]
    private void RequestForget(DeviceItem? item)
    {
        if (item is not null) ForgetRequested?.Invoke(item);
    }

    [RelayCommand]
    private void CopyAddress(DeviceItem? item)
    {
        if (item is null || item.Addr.Length == 0) return;
        try { Clipboard.SetText(item.Addr); } catch { /* 剪贴板被占用 */ }
    }

    /// <summary>备注名写回（对话框确认后由 View 调这里）。</summary>
    public Task SetAlias(string key, string alias) =>
        RunAction(new ActionRequest(key, "alias", alias));

    public Task Forget(string key) => RunAction(new ActionRequest(key, "forget"));

    public Task Disconnect(string key) => RunAction(new ActionRequest(key, "disconnect"));

    [RelayCommand]
    private async Task RunAction(ActionRequest req)
    {
        await Task.Run(() => _backend.RunAction(req.Key, req.Op, req.Alias));
        await RefreshAsync(deep: false);
    }

    [RelayCommand]
    private void TogglePreferUsb()
    {
        _backend.SetPreferUsb(PreferUsb);
        _ = RefreshAsync(deep: false);
    }

    // ---- 提示卡片 ----

    private System.Windows.Threading.DispatcherTimer? _toastTimer;

    /// <summary>state: '' 进行中 / ok / err / warn；autoHideMs=0 表示不自动收起。</summary>
    public void Toast(string state, string title, string sub, int autoHideMs)
    {
        ToastState = state;
        ToastTitle = title;
        ToastSub = sub;
        ToastVisible = true;

        _toastTimer?.Stop();
        if (autoHideMs > 0)
        {
            _toastTimer = new System.Windows.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(autoHideMs),
            };
            _toastTimer.Tick += (_, _) =>
            {
                _toastTimer!.Stop();
                ToastVisible = false;
            };
            _toastTimer.Start();
        }
    }

    public void HideToast()
    {
        _toastTimer?.Stop();
        ToastVisible = false;
    }

    /// <summary>右键菜单里的杂项动作参数。</summary>
    public sealed record ActionRequest(string Key, string Op, string? Alias = null);

    public void Stop()
    {
        _timer.Stop();
        _navs?.Dispose();   // 主窗口关了条子也得收掉，不能留一堆孤儿 HUD
        // 关窗即退出：终止全部进行中的 adb 传输（不留孤儿进程与半包）
        Transfer.Dispose();
    }
}
