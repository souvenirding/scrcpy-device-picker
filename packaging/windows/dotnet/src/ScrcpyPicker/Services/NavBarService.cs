using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using ScrcpyPicker.Views;

namespace ScrcpyPicker.Services;

/// <summary>
/// 导航条的管家：一台正在投屏的设备一条按钮条，60ms 一次跟着 scrcpy 窗口贴。
///
/// 为什么要有这条：三键手机（没有全面屏手势）在投屏画面里点不到返回/桌面/多任务，
/// 人只能回到手机跟前操作。右键菜单能发键，但每次都要回主窗口点一行，
/// 投屏时根本不想看见主窗口。所以按键条得跟着投屏窗口走。
///
/// 三条从旧 PowerShell 版继承下来的硬规矩：
///   * GetWindowRect 是物理像素，Window.Left/Top/Width 是 DIP，必须除以 TransformToDevice.M11；
///   * 吸附时每帧无条件赋 Width。"变了才赋"是个陷阱：SizeToContent 刚切到 Height 的那一刻
///     Width 的本地值是 NaN，跟任何数比差值都不成立，条子会永远没有宽度；
///   * DispatcherTimer 不 Start() 永远不 Tick。
/// </summary>
public sealed class NavBarService : IDisposable
{
    private sealed class Entry
    {
        public required NavBarWindow Window { get; init; }
        public required string Key { get; init; }
        public string Label { get; set; } = string.Empty;
        public int Pid { get; set; }
        public IntPtr Hwnd { get; set; }
        public bool Docked { get; set; } = true;
        public bool Iconic { get; set; }
        public string Place { get; set; } = string.Empty;
        public bool TitleHidden { get; set; }
    }

    private readonly List<Entry> _entries = new();
    private readonly DispatcherTimer _timer;
    private readonly Func<string, int, Task> _sendKey;
    private readonly Action<string> _notice;
    private readonly Func<int, bool> _isScrcpyAlive;
    private bool _enabled = true;
    private bool _disposed;

    /// <summary>
    /// 三个回调都由界面层给：发按键（含错误提示）、往状态区写一句话、判断某个 PID
    /// 是否还是一个活着的 scrcpy（复用 CastManager 的判据，防 PID 被回收复用）。
    /// </summary>
    public NavBarService(Func<string, int, Task> sendKey, Action<string> notice, Func<int, bool> isScrcpyAlive)
    {
        _sendKey = sendKey;
        _notice = notice;
        _isScrcpyAlive = isScrcpyAlive;

        // 60ms：拖动投屏窗口时要"看起来是粘在一起的"，而 GetWindowRect 便宜到可以忽略。
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
        _timer.Tick += (_, _) => Follow();
    }

    public int Count => _entries.Count;

    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (_enabled == value) return;
            _enabled = value;
            foreach (Entry e in _entries)
            {
                if (value) e.Window.Show();
                else e.Window.Hide();
            }
            if (value) Start();
        }
    }

    /// <summary>
    /// 保证这台设备有一条导航条。pid 是这一轮投屏的 scrcpy 进程号。
    /// 同一台设备重复投屏（新窗口 = 新句柄）时不新建条子，而是把它重新吸回去。
    /// </summary>
    public void Ensure(string key, string label, int pid)
    {
        if (_disposed || key.Length == 0 || pid <= 0) return;

        Entry? hit = _entries.FirstOrDefault(e => e.Key == key);
        if (hit is not null)
        {
            hit.Pid = pid;
            hit.Hwnd = IntPtr.Zero;
            hit.Iconic = false;
            hit.Place = string.Empty;
            hit.Label = label;
            hit.Window.DeviceLabel = label;
            SetDocked(hit, docked: true);
            hit.Window.WindowState = WindowState.Normal;
            hit.Window.Show();
            Start();
            Follow();
            return;
        }

        var win = new NavBarWindow { DeviceLabel = label };
        var entry = new Entry { Window = win, Key = key, Label = label, Pid = pid };

        win.KeyClicked += (code, name) => _ = _sendKey(key, code);
        win.DockModeRequested += dock => SetDocked(entry, dock);
        win.CloseRequested += () => CloseEntry(entry);
        win.Closed += (_, _) => _entries.Remove(entry);

        _entries.Add(entry);
        win.Show();
        win.UpdateLayout();

        // 先落在右下角：scrcpy 窗口通常还要一两秒才出现，跟随循环会从那里把它吸过去。
        Rect wa = SystemParameters.WorkArea;
        int idx = Math.Max(0, _entries.Count - 1);
        win.Left = wa.Right - win.ActualWidth - 22 - 26 * idx;
        win.Top = wa.Bottom - win.ActualHeight - 22 - 44 * idx;
        if (win.Top < wa.Top) win.Top = wa.Top + 20;

        Start();
        Follow();
    }

    /// <summary>这台设备的投屏结束了（或被强制重开前清场），条子跟着走。</summary>
    public void CloseFor(string key)
    {
        foreach (Entry e in _entries.Where(e => e.Key == key).ToList()) CloseEntry(e);
    }

    public void CloseAll()
    {
        foreach (Entry e in _entries.ToList()) CloseEntry(e);
    }

    private void CloseEntry(Entry e)
    {
        _entries.Remove(e);
        try { e.Window.Close(); } catch { /* 已经在关闭流程里 */ }
        if (_entries.Count == 0) _timer.Stop();
    }

    private void Start()
    {
        if (!_timer.IsEnabled) _timer.Start();
    }

    /// <summary>拖动=脱离，双击=吸附。样式切换集中在这里，避免两处各改一半。</summary>
    private void SetDocked(Entry e, bool docked)
    {
        if (e.Docked == docked) return;
        e.Docked = docked;
        e.Place = string.Empty;
        e.TitleHidden = false;

        if (docked)
        {
            e.Window.DeviceLabel = e.Label;
            e.Window.ApplyDockedStyle();
            e.Hwnd = ResolveHwnd(e.Pid);
            _notice("导航条已重新吸附到投屏窗口。");
            Follow();
        }
        else
        {
            e.Window.ApplyFloatingStyle();
            _notice("导航条已脱离，可自由拖动；双击它重新吸附到投屏窗口。");
        }
    }

    /// <summary>scrcpy 自己只有一个 SDL 窗口，所以 PID 就是查找键；窗口没起来时句柄是 0，下一帧再试。</summary>
    private static IntPtr ResolveHwnd(int pid)
    {
        if (pid <= 0) return IntPtr.Zero;
        try
        {
            using var p = Process.GetProcessById(pid);
            IntPtr h = p.MainWindowHandle;
            return h != IntPtr.Zero && User32.IsWindow(h) ? h : IntPtr.Zero;
        }
        catch (ArgumentException) { return IntPtr.Zero; }        // 进程已经没了
        catch (InvalidOperationException) { return IntPtr.Zero; }
    }

    private static double ScaleOf(Window w)
    {
        try
        {
            PresentationSource? src = PresentationSource.FromVisual(w);
            double m = src?.CompositionTarget.TransformToDevice.M11 ?? 0;
            if (m > 0) return m;
        }
        catch
        {
            // 窗口句柄还没建好时拿不到 source，按 1 处理，下一帧再校准
        }
        return 1;
    }

    /// <summary>每一帧：进程没了就收条子，吸附着的贴到投屏窗口下沿。</summary>
    private void Follow()
    {
        if (_disposed) return;
        if (_entries.Count == 0)
        {
            _timer.Stop();
            return;
        }
        if (!_enabled) return;

        Rect raw = SystemParameters.WorkArea;
        var work = new DipRect(raw.X, raw.Y, raw.Width, raw.Height);

        foreach (Entry e in _entries.ToList())
        {
            if (!_isScrcpyAlive(e.Pid))
            {
                // 投屏进程退出（用户自己关了窗口 / 设备掉线），条子留着没意义
                CloseEntry(e);
                continue;
            }
            if (!e.Docked) continue;   // 悬浮中由用户说了算

            if (e.Hwnd == IntPtr.Zero || !User32.IsWindow(e.Hwnd)) e.Hwnd = ResolveHwnd(e.Pid);
            if (e.Hwnd == IntPtr.Zero) continue;   // 窗口还没出现

            if (User32.IsIconic(e.Hwnd))
            {
                // 投屏窗口最小化时条子也要跟着藏，否则桌面上留一条没人用的按钮条
                if (e.Window.IsVisible && !e.Iconic)
                {
                    e.Iconic = true;
                    e.Window.Hide();
                }
                continue;
            }
            if (e.Iconic)
            {
                e.Iconic = false;
                e.Window.Show();
            }

            if (!User32.GetWindowRect(e.Hwnd, out User32.RECT rc)) continue;
            var mirror = NavBarLayout.ToDips(
                new PhysicalRect(rc.Left, rc.Top, rc.Right, rc.Bottom), ScaleOf(e.Window));
            if (!NavBarLayout.IsSaneMirror(mirror)) continue;

            if (e.Window.SizeToContent != SizeToContent.Height) e.Window.SizeToContent = SizeToContent.Height;
            e.Window.Width = mirror.Width;      // 无条件赋值，理由见类注释
            e.Window.Left = mirror.Left;
            e.Window.UpdateLayout();

            double barHeight = e.Window.ActualHeight;
            var (kind, top) = NavBarLayout.Place(mirror, barHeight, work);
            e.Window.Top = top;

            if (e.Place != kind)
            {
                e.Window.ApplyDockStyle(kind);
                e.Place = kind;
            }
            if (!e.TitleHidden)
            {
                e.Window.SetShowTitle(false);
                e.TitleHidden = true;
            }

            // 压在画面里（最大化投屏）时必须置顶，否则条子会躲到 scrcpy 窗口背后，
            // 变成"看起来导航条消失了"。贴在窗口外面时不置顶，免得挡住别的应用。
            bool wantTopmost = kind == NavBarLayout.Inside;
            if (e.Window.Topmost != wantTopmost) e.Window.Topmost = wantTopmost;
            if (!e.Window.IsVisible) e.Window.Show();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _timer.Stop();
        CloseAll();
    }
}
