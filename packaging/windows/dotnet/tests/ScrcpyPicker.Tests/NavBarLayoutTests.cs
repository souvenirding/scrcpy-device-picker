using System.IO;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 导航条吸附几何的无头单测。
/// 这些数字错了在界面上就是"条子跑到屏幕外""被任务栏吃掉""最大化时看不见"，
/// 而那三种情况都很难靠肉眼在自动化里抓，所以全部钉在这里。
/// </summary>
public class NavBarLayoutTests
{
    private static readonly DipRect Work = new(0, 0, 1920, 1040);   // 1080 减任务栏

    [Fact]
    public void ToDips_dividesPhysicalPixelsByTheScale()
    {
        // 本机 150% 缩放：物理 1500 宽 = DIP 1000
        var r = new PhysicalRect(150, 300, 1650, 1200);
        DipRect d = NavBarLayout.ToDips(r, 1.5);
        Assert.Equal(100, d.Left, 6);
        Assert.Equal(200, d.Top, 6);
        Assert.Equal(1000, d.Width, 6);
        Assert.Equal(600, d.Height, 6);
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(-1.0)]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    public void ToDips_brokenScale_fallsBackToOneInsteadOfNaN(double scale)
    {
        DipRect d = NavBarLayout.ToDips(new PhysicalRect(10, 20, 110, 220), scale);
        Assert.False(double.IsNaN(d.Left));
        Assert.Equal(100, d.Width, 6);
        Assert.Equal(200, d.Height, 6);
    }

    [Fact]
    public void IsSaneMirror_rejectsTheZeroRectAndAbsurdWidths()
    {
        Assert.False(NavBarLayout.IsSaneMirror(new DipRect(0, 0, 0, 0)));          // 还没建好的窗口
        Assert.False(NavBarLayout.IsSaneMirror(new DipRect(0, 0, 40, 300)));       // 窄过阈值
        Assert.False(NavBarLayout.IsSaneMirror(new DipRect(0, 0, 30000, 300)));    // 跨虚拟桌面的坏值
        Assert.True(NavBarLayout.IsSaneMirror(new DipRect(0, 0, 60, 300)));
        Assert.True(NavBarLayout.IsSaneMirror(new DipRect(-1200, 80, 900, 1600))); // 副屏负坐标是合法的
    }

    [Fact]
    public void Place_sitsFlushUnderTheWindowWhenThereIsRoom()
    {
        var mirror = new DipRect(300, 120, 800, 500);   // 底边 620
        var (kind, top) = NavBarLayout.Place(mirror, 46, Work);
        Assert.Equal(NavBarLayout.Below, kind);
        Assert.Equal(621, top, 6);                      // 620 + 1px 缝
    }

    [Fact]
    public void Place_flipsAboveWhenTheTaskbarWouldEatIt()
    {
        var mirror = new DipRect(300, 400, 800, 620);   // 底边 1020，下面放不下 46
        var (kind, top) = NavBarLayout.Place(mirror, 46, Work);
        Assert.Equal(NavBarLayout.Above, kind);
        Assert.Equal(353, top, 6);                      // 400 - 46 - 1
    }

    [Fact]
    public void Place_overlaysTheBottomEdgeWhenMaximizedHasNoRoomEitherSide()
    {
        var mirror = new DipRect(0, 0, 1920, 1040);     // 正好铺满工作区
        var (kind, top) = NavBarLayout.Place(mirror, 46, Work);
        Assert.Equal(NavBarLayout.Inside, kind);
        Assert.Equal(991, top, 6);                      // 1040 - 46 - 3
    }

    [Fact]
    public void Place_neverGoesAboveTheWorkArea()
    {
        // 窗口被拖到最顶上，且下面放不下：翻到上面会顶出工作区，必须压回来
        var mirror = new DipRect(100, 0, 800, 1040);
        var (kind, top) = NavBarLayout.Place(mirror, 46, Work);
        Assert.Equal(NavBarLayout.Inside, kind);
        Assert.True(top >= Work.Top + 1);
    }

    [Fact]
    public void Place_usesAPlaceholderHeightBeforeLayoutHasRun()
    {
        // ActualHeight 在第一次布局前是 0；按 0 算的话条子会贴到窗口下沿外 1px 处变成一条线
        var mirror = new DipRect(0, 0, 1920, 1040);
        var (kind, top) = NavBarLayout.Place(mirror, 0, Work);
        Assert.Equal(NavBarLayout.Inside, kind);
        Assert.Equal(997, top, 6);                      // 高度兜底成 40：1040 - 40 - 3
    }

    [Fact]
    public void Corners_squaresOffTheEdgeThatTouchesTheMirror()
    {
        Assert.Equal((0, 0, 12, 12), NavBarLayout.Corners(NavBarLayout.Below));
        Assert.Equal((12, 12, 0, 0), NavBarLayout.Corners(NavBarLayout.Above));
        Assert.Equal((10d, 10d, 10d, 10d), NavBarLayout.Corners(NavBarLayout.Inside));
    }
}

/// <summary>导航条开关的落盘行为（配置文件兼容性：老文件没这个键）。</summary>
public class NavBarSettingTests
{
    [Fact]
    public void NavBar_defaultsToOn_whenTheFileNeverMentionedIt()
    {
        string dir = Path.Combine(Path.GetTempPath(), "picker-navbar-cfg-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        try
        {
            // 旧版（Go / PowerShell）的 devices.json：settings 里没有 navBar
            File.WriteAllText(Path.Combine(dir, "devices.json"),
                """
                { "devices": {}, "settings": { "preferUsb": false, "scanSubnet": true, "toolDir": "" } }
                """);

            var cfg = new ConfigService(dir);
            Assert.True(cfg.NavBar());
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* 临时目录留着也无害 */ }
        }
    }

    [Fact]
    public void NavBar_off_survivesAReload_andDoesNotDisturbOtherSettings()
    {
        string dir = Path.Combine(Path.GetTempPath(), "picker-navbar-cfg-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            var cfg = new ConfigService(dir);
            cfg.SetPreferUsb(true);
            cfg.SetToolDir(@"E:\Flash\tools\scrcpy");
            Assert.True(cfg.NavBar());

            cfg.SetNavBar(false);
            var again = new ConfigService(dir);
            Assert.False(again.NavBar());
            Assert.True(again.Settings().PreferUsb);
            Assert.Equal(@"E:\Flash\tools\scrcpy", again.ToolDir());

            again.SetNavBar(true);
            Assert.True(new ConfigService(dir).NavBar());
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { /* 忽略 */ }
        }
    }
}
