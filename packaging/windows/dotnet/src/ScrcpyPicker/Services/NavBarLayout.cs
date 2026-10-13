namespace ScrcpyPicker.Services;

/// <summary>user32 的窗口矩形（物理像素）。</summary>
public readonly record struct PhysicalRect(int Left, int Top, int Right, int Bottom);

/// <summary>WPF 用的矩形（设备无关单位 DIP）。</summary>
public readonly record struct DipRect(double Left, double Top, double Width, double Height)
{
    public double Right => Left + Width;
    public double Bottom => Top + Height;
}

/// <summary>
/// 导航条"吸附"到投屏窗口的纯几何计算。
///
/// 单独拎出来的理由有两个：
///   1. 这是整个导航条里唯一会算错就看得见后果的部分（贴歪、被任务栏吃掉、
///      或者在投屏窗口最小化时留下一条孤零零的按钮条），必须能无头单测；
///   2. 它不碰任何 WPF 类型，测试项目不用起 STA 线程。
///
/// 数值与阈值照旧 PowerShell 版 Update-NavDock 的实测结果，包括"最大化时压在
/// 视频画面下沿"这条兜底——那是唯一在最大化投屏窗口下还能点到按键的放法。
/// </summary>
public static class NavBarLayout
{
    /// <summary>投屏窗口和按钮条之间留 1 DIP 缝，视觉上两条描边不至于糊成一团。</summary>
    public const double Gap = 1;

    /// <summary>窄于此值说明拿到的是坏矩形（0,0,0,0 或跨虚拟桌面的负坐标）。</summary>
    public const double MinMirrorWidth = 60;

    public const double MaxMirrorWidth = 20000;

    public const string Below = "below";
    public const string Above = "above";
    public const string Inside = "inside";

    /// <summary>
    /// 物理像素 → DIP。GetWindowRect 给的是物理像素，而 Window.Left/Top/Width 是 DIP，
    /// 本机跑 150% 缩放，这一除不是可选项（旧版踩过：不除的话条子会飞到屏幕外）。
    /// scale 传 0 / 负数 / NaN 时按 1 处理，宁可贴得偏一点也不要算出 NaN 把窗口甩没。
    /// </summary>
    public static DipRect ToDips(PhysicalRect r, double scale)
    {
        double s = scale;
        if (double.IsNaN(s) || double.IsInfinity(s) || s <= 0) s = 1;
        return new DipRect(r.Left / s, r.Top / s, (r.Right - r.Left) / s, (r.Bottom - r.Top) / s);
    }

    /// <summary>矩形是否可信到值得跟着走。</summary>
    public static bool IsSaneMirror(DipRect mirror) =>
        mirror.Width >= MinMirrorWidth && mirror.Width <= MaxMirrorWidth && mirror.Height > 0;

    /// <summary>
    /// 决定按钮条的纵向位置：优先贴在投屏窗口下沿外面；下面被任务栏/屏幕边吃掉就翻到上面；
    /// 上下都不够（最大化）就压在窗口内下沿。返回 (放法, Top)。
    /// </summary>
    public static (string Kind, double Top) Place(DipRect mirror, double barHeight, DipRect work)
    {
        double h = barHeight < 10 ? 40 : barHeight;   // 布局还没算出来时 ActualHeight 是 0
        double y = mirror.Bottom + Gap;
        string kind = Below;

        if (y + h > work.Bottom)
        {
            if (mirror.Top - h - Gap >= work.Top)
            {
                kind = Above;
                y = mirror.Top - h - Gap;
            }
            else
            {
                kind = Inside;
                y = mirror.Bottom - h - 3;
            }
        }

        // 翻到上面时可能顶出工作区（投屏窗口被拖到屏幕最上边），压回来。
        if (y < work.Top + 1) y = work.Top + 1;
        return (kind, y);
    }

    /// <summary>
    /// 哪种放法对应哪对圆角：贴着窗口的那两条边要方角，两条描边才读成一块面板。
    /// 返回值是 Border.CornerRadius 的 (左上, 右上, 右下, 左下)。
    /// </summary>
    public static (double TopLeft, double TopRight, double BottomRight, double BottomLeft) Corners(string kind) =>
        kind switch
        {
            Above => (12, 12, 0, 0),
            Inside => (10, 10, 10, 10),
            _ => (0, 0, 12, 12),
        };
}
