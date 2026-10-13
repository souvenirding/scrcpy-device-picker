using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 设备发现的纯解析层。
///
/// 这些用例是整块改造里最值钱的回归网：分类规则和哨兵分段都是从旧版 bug 里改出来的，
/// 没有真机也能逐条验，所以全部拆成了 static 方法。
/// </summary>
public class DiscoveryParseTests
{
    // ---- 传输分类 ----

    [Theory]
    // mDNS 服务名：串号里没有冒号，但它是无线调试。旧版就是按"有没有冒号"判断，把这类认成了 USB。
    [InlineData("adb-192.0.2.50-43210-_adb-tls-connect._tcp", TransportKind.Tls)]
    [InlineData("adb-ZJ5T7NL8-MY-_adb-tls-connect._tcp", TransportKind.Tls)]
    // 传统 adb tcpip：固定端口 5555
    [InlineData("192.0.2.50:5555", TransportKind.Tcp5555)]
    // 随机端口的 ip:port 仍按无线调试算
    [InlineData("192.0.2.50:37183", TransportKind.Tls)]
    // 纯串号才是 USB
    [InlineData("c1e5d47a", TransportKind.Usb)]
    [InlineData("emulator-5554", TransportKind.Usb)]
    [InlineData("", TransportKind.Usb)]
    public void ClassifyTransport_follows_shape_not_colon(string serial, TransportKind want) =>
        Assert.Equal(want, DiscoveryService.ClassifyTransport(serial));

    [Fact]
    public void ParseDeviceList_keepsOnlyDeviceLines_andExtractsModelProduct()
    {
        string[] lines =
        {
            "List of devices attached",
            "c1e5d47a               device product:samplea model:Sample_Model_A device:samplea transport_id:1",
            "adb-203.0.113.9-50432-_adb-tls-connect._tcp device product:sampleb model:Sample_Model_B device:sampleb transport_id:2",
            "203.0.113.9:5555       device product:sampleb model:Sample_Model_B device:sampleb transport_id:3",
            "deadbeef               unauthorized product:x model:y device:z transport_id:4",
            "offline01              offline product:x model:y device:z transport_id:5",
            "",
        };

        List<Transport> got = DiscoveryService.ParseDeviceList(lines);

        Assert.Equal(3, got.Count);
        Assert.Equal("c1e5d47a", got[0].Serial);
        Assert.Equal("Sample_Model_A", got[0].Model);
        Assert.Equal("samplea", got[0].Product);
        Assert.Equal(TransportKind.Usb, got[0].Kind);
        Assert.Equal(TransportKind.Tls, got[1].Kind);
        Assert.Equal("Sample_Model_B", got[1].Model);
        Assert.Equal(TransportKind.Tcp5555, got[2].Kind);
    }

    [Fact]
    public void ParseDeviceList_lineWithoutModel_yieldsEmptyModel()
    {
        List<Transport> got = DiscoveryService.ParseDeviceList(new[] { "abc123   device" });
        Assert.Single(got);
        Assert.Equal(string.Empty, got[0].Model);
        Assert.Equal(string.Empty, got[0].Product);
    }

    [Fact]
    public void ParseDeviceList_headerOnly_isEmpty() =>
        Assert.Empty(DiscoveryService.ParseDeviceList(new[] { "List of devices attached", "* daemon not running; starting now" }));

    // ---- adb 现役状态表 ----

    [Fact]
    public void ParseDeviceStates_mapsSerialToState()
    {
        var live = DiscoveryService.ParseDeviceStates(new[]
        {
            "List of devices attached",
            "c1e5d47a        device",
            "203.0.113.9:5555        offline",
            "deadbeef        unauthorized",
            "garbage",
        });

        Assert.Equal("device", live["c1e5d47a"]);
        Assert.Equal("offline", live["203.0.113.9:5555"]);
        Assert.Equal("unauthorized", live["deadbeef"]);
        // 只有一个词的行（以及 adb 的提示语）进不了表：这就是 "garbage" 不在键里的原因。
        Assert.False(live.ContainsKey("garbage"));
    }

    // ---- 目标选择 ----

    [Fact]
    public void CandidateTargets_ordersPrefUsbTlsTcpKey_andDropsEmptyAndDuplicates()
    {
        List<string> cands = DiscoveryService.CandidateTargets(
            key: "c1e5d47a", preferred: "", usbSerial: "c1e5d47a", tls: "adb-x._adb-tls-connect._tcp", tcp5555: "");

        Assert.Equal(new List<string> { "c1e5d47a", "adb-x._adb-tls-connect._tcp" }, cands);
    }

    [Fact]
    public void ChooseTarget_picksFirstActuallyLiveDevice()
    {
        var live = new Dictionary<string, string>
        {
            ["tls-name"] = "offline",
            ["usb-serial"] = "device",
        };
        var cands = new List<string> { "tls-name", "usb-serial", "tcp-5555" };

        Assert.Equal("usb-serial", DiscoveryService.ChooseTarget(cands, live));
    }

    [Fact]
    public void ChooseTarget_fallsBackToFirstCandidate_soScrcpyReportsTheRealError()
    {
        var cands = new List<string> { "tls-name", "usb-serial" };
        // 一个都不在线时不能返回空串：让 scrcpy/adb 自己报真正的错，而不是静默失败。
        Assert.Equal("tls-name", DiscoveryService.ChooseTarget(cands, new Dictionary<string, string>()));
        Assert.Equal(string.Empty, DiscoveryService.ChooseTarget(new List<string>(), new Dictionary<string, string>()));
    }

    // ---- 详情分段解析 ----

    private static string[] DetailLines(string modelSection = "MK_S2", string model = "Mi 10 Pro")
    {
        var lines = new List<string>
        {
            "MK_S1", "c1e5d47a",
            modelSection, model,
            "MK_S3", "sampleb",
            "MK_S4", "13",
            "MK_S5", "Xiaomi",
            "MK_S6", "null",
            "MK_S7", "inet 192.0.2.50/24 brd 192.0.2.255 scope global wlan0",
            "MK_S8", "  level: 87", "  status: 2", "  voltage: 4200000",
        };
        return lines.ToArray();
    }

    [Fact]
    public void ParseDetail_readsEverySection()
    {
        DeviceDetail? d = DiscoveryService.ParseDetail(DetailLines());

        Assert.NotNull(d);
        Assert.Equal("c1e5d47a", d!.SerialNo);
        Assert.Equal("Mi 10 Pro", d.Model);
        Assert.Equal("sampleb", d.Device);
        Assert.Equal("13", d.Android);
        Assert.Equal("Xiaomi", d.Brand);
        // settings get 返回字面量 "null" 时按空处理，界面上才不会显示一个 null
        Assert.Equal(string.Empty, d.DevName);
        Assert.Equal("192.0.2.50", d.WifiIp);
        Assert.Equal("87", d.Battery);
        Assert.Equal("充电中", d.Charging);
    }

    [Theory]
    [InlineData("  status: 2", "充电中")]
    [InlineData("  status: 3", "放电")]
    [InlineData("  status: 4", "已充满")]
    [InlineData("  status: 1", "")]
    public void ParseDetail_mapsBatteryStatus(string statusLine, string want)
    {
        var lines = new List<string> { "MK_S1", "s", "MK_S2", "m", "MK_S8", "  level: 42", statusLine };
        DeviceDetail? d = DiscoveryService.ParseDetail(lines.ToArray());
        Assert.NotNull(d);
        Assert.Equal("42", d!.Battery);
        Assert.Equal(want, d.Charging);
    }

    [Fact]
    public void ParseDetail_withoutModel_isInvalid()
    {
        // 拿不到型号多半是设备刚掉线/没授权，整份详情按无效处理，别把半截数据写进缓存。
        Assert.Null(DiscoveryService.ParseDetail(new[] { "MK_S1", "serial", "MK_S3", "sampleb" }));
        Assert.Null(DiscoveryService.ParseDetail(Array.Empty<string>()));
    }

    [Fact]
    public void ParseDetail_survivesCarriageReturns_andMissingSections()
    {
        DeviceDetail? d = DiscoveryService.ParseDetail(new[] { "MK_S1\r", "serial\r", "MK_S2\r", "Pixel 6\r" });
        Assert.NotNull(d);
        Assert.Equal("serial", d!.SerialNo);
        Assert.Equal("Pixel 6", d.Model);
        Assert.Equal(string.Empty, d.Android);
        Assert.Equal(string.Empty, d.Battery);
    }

    [Fact]
    public void ParseDetail_ignoresTextBeforeTheFirstSentinel()
    {
        DeviceDetail? d = DiscoveryService.ParseDetail(new[]
        {
            "* daemon not running; starting now at tcp:5037",
            "MK_S2", "Model X",
        });
        Assert.NotNull(d);
        Assert.Equal("Model X", d!.Model);
        Assert.Equal(string.Empty, d.SerialNo);
    }

    // ---- 传输名 -> 真实串号 ----

    [Fact]
    public void RememberAndSerialOf_keepTheTransportToSerialMapping()
    {
        using var tmp = new TempDir();
        var svc = new DiscoveryService(
            new ToolchainHolder(ToolchainSnapshot.Empty), new ConfigService(tmp.Path));

        // 没记过的名字原样返回：调用方永远能拿到一个可以喂给 adb 的串。
        Assert.Equal("c1e5d47a", svc.SerialOf("c1e5d47a"));

        svc.Remember("adb-x-_adb-tls-connect._tcp", "c1e5d47a");
        Assert.Equal("c1e5d47a", svc.SerialOf("adb-x-_adb-tls-connect._tcp"));
    }

    [Fact]
    public void AdbCalls_onAnUnresolvedToolchain_returnNoLines_notAnError()
    {
        // 找不到 adb 与没有设备是两码事：这里必须给"没有输出"，让上层报路径问题。
        Assert.Empty(ToolchainService.Adb(ToolchainSnapshot.Empty, new[] { "devices" }));
        Assert.Equal(string.Empty, ToolchainService.AdbText(ToolchainSnapshot.Empty, new[] { "version" }));
        Assert.Equal(string.Empty, ToolchainService.AdbVersion(ToolchainSnapshot.Empty));
        Assert.Equal(string.Empty, ToolchainService.ScrcpyVersion(ToolchainSnapshot.Empty));
    }
}
