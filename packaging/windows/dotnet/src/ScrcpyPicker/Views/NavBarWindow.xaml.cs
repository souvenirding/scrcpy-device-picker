using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace ScrcpyPicker.Views;

/// <summary>
/// 导航条窗口（View）。它只画按钮、把"点了哪颗/被拖了/被关了"报出去，
/// 什么时候贴到哪、发给哪台设备，全在 <see cref="Services.NavBarService"/>。
/// </summary>
public partial class NavBarWindow : Window
{
    public NavBarWindow()
    {
        InitializeComponent();
        Shell.ToolTip = "拖动=脱离投屏窗口浮起来  ·  双击=重新吸附  ·  ✕=只关按钮条";
    }

    /// <summary>某颗按键被点了：参数是 Android keyevent 码和它的中文名（状态栏要用）。</summary>
    public event Action<int, string>? KeyClicked;

    /// <summary>true=用户双击要求重新吸附；false=用户拖动要求脱离。</summary>
    public event Action<bool>? DockModeRequested;

    /// <summary>✕ 被点了：只关这一条，不影响投屏。</summary>
    public event Action? CloseRequested;

    /// <summary>设备名/串号，显示在条子左边的标题上。</summary>
    public string DeviceLabel
    {
        get => NavTitle.Text;
        set => NavTitle.Text = "导航键 · " + value;
    }

    private void OnKeyClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn) return;
        // 码写在 Tag 上（XAML 里是字符串），不闭包捕获，避免以后复用窗口时发错设备。
        if (!int.TryParse(Convert.ToString(btn.Tag), out int code)) return;
        KeyClicked?.Invoke(code, Convert.ToString(btn.Content) ?? string.Empty);
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();

    /// <summary>
    /// 空白处按下：双击=吸附，拖动=脱离。
    /// 点在按钮上不会走到这里（Button 先把事件吃掉），所以"拖一下就发错键"不可能发生。
    /// </summary>
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        if (e.ClickCount >= 2)
        {
            DockModeRequested?.Invoke(true);
            e.Handled = true;
            return;
        }
        try
        {
            DragMove();
            DockModeRequested?.Invoke(false);
            e.Handled = true;
        }
        catch (InvalidOperationException)
        {
            // 左键已经松开（极快的点击）时 DragMove 会抛，忽略即可
        }
    }

    /// <summary>吸附时标题让位给投屏窗口自己的标题栏，窄窗口下七颗键才留得在一行里。</summary>
    public void SetShowTitle(bool show)
    {
        Visibility want = show ? Visibility.Visible : Visibility.Collapsed;
        if (NavTitle.Visibility != want) NavTitle.Visibility = want;
    }

    /// <summary>
    /// 按放法（below/above/inside）改圆角和内边距：贴着投屏窗口的那对角要方掉，
    /// 两块面板才读成一块。kind 传 Services.NavBarLayout 里的常量。
    /// </summary>
    public void ApplyDockStyle(string kind)
    {
        (double tl, double tr, double br, double bl) = Services.NavBarLayout.Corners(kind);
        Shell.CornerRadius = new CornerRadius(tl, tr, br, bl);
        Shell.Padding = kind == Services.NavBarLayout.Inside
            ? new Thickness(10, 6, 10, 6)
            : new Thickness(10, 5, 10, 5);
    }

    /// <summary>脱离悬浮后的样子：回到自适应宽高、始终置顶、把标题亮出来提示可以双击吸附。</summary>
    public void ApplyFloatingStyle()
    {
        // 先清掉吸附期间被逐帧写进去的本地 Width，再交回 SizeToContent：
        // WPF 里有显式本地值时 SizeToContent 会被忽略，顺序反了条子就停在旧宽度上。
        Width = double.NaN;
        SizeToContent = SizeToContent.WidthAndHeight;
        Topmost = true;
        SetShowTitle(true);
        Shell.CornerRadius = new CornerRadius(12);
        Shell.Padding = new Thickness(10, 7, 10, 7);
    }

    /// <summary>重新吸附：宽度交给跟随循环去钉。</summary>
    public void ApplyDockedStyle()
    {
        SizeToContent = SizeToContent.Height;
        Topmost = false;
        Shell.CornerRadius = new CornerRadius(12);
        Shell.Padding = new Thickness(10, 7, 10, 7);
    }
}
