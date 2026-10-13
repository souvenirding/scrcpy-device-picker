using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 界面行组装。这一层直接决定表格里显示什么，字段语义和旧前端 app.js 读的完全一致。
/// </summary>
public class WebRowsTests
{
    private static DeviceRow Online(string key) => new()
    {
        Key = key,
        Model = "Mi 10 Pro",
        Device = "sampleb",
        Android = "13",
        DevName = "小米 10 Pro",
        Battery = "87",
        Charging = "充电中",
        Online = true,
    };

    [Fact]
    public void Build_prefersAliasThenDeviceNameThenModelThenKey()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);
        cfg.SetDevice("k-alias", new DeviceCache { Alias = "主力机", DevName = "手机原名", Model = "M" });
        cfg.SetDevice("k-devname", new DeviceCache { DevName = "平板原名", Model = "M" });

        var online = new List<DeviceRow>
        {
            new() { Key = "k-alias", DevName = "手机原名", Model = "M" },
            new() { Key = "k-devname", DevName = "平板原名", Model = "M" },
            new() { Key = "k-model", DevName = string.Empty, Model = "Sample_Model_A" },
            new() { Key = "k-plain", DevName = string.Empty, Model = string.Empty },
        };

        List<WebRow> rows = WebRows.Build(online, cfg);

        Assert.Equal("主力机", rows.Single(r => r.Key == "k-alias").Name);
        Assert.Equal("平板原名", rows.Single(r => r.Key == "k-devname").Name);
        Assert.Equal("Sample_Model_A", rows.Single(r => r.Key == "k-model").Name);
        Assert.Equal("k-plain", rows.Single(r => r.Key == "k-plain").Name);
    }

    [Fact]
    public void Build_marksChannelsAndPicksTheAddress()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);

        DeviceRow r = Online("c1e5d47a");
        r.Usb = true;
        r.UsbSerial = "c1e5d47a";
        r.Tls = "adb-x-_adb-tls-connect._tcp";
        r.Preferred = "c1e5d47a";

        WebRow row = WebRows.Build(new List<DeviceRow> { r }, cfg).Single();

        Assert.Equal(new List<string> { "USB", "TLS" }, row.Conn);
        Assert.Equal("USB  +  无线调试", row.ConnText);
        // 地址优先给无线调试的传输名，USB 串号当地址没有意义
        Assert.Equal("adb-x-_adb-tls-connect._tcp", row.Addr);
        Assert.Equal("87% 充电中", row.BatteryText);
        Assert.True(row.Online);
        Assert.False(row.Offline);
        Assert.Equal("c1e5d47a", row.Preferred);
    }

    [Fact]
    public void Build_usesTheLiveTcp5555TransportAsAddress()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);

        DeviceRow r = Online("deadbeef");
        r.WifiIp = "192.0.2.50";
        r.Tcp5555 = "192.0.2.50:5555";

        WebRow row = WebRows.Build(new List<DeviceRow> { r }, cfg).Single();

        Assert.Equal(new List<string> { "TCP" }, row.Conn);
        Assert.Equal("TCP 5555", row.ConnText);
        Assert.Equal("192.0.2.50:5555", row.Addr);
    }

    [Fact]
    public void Build_rebuildsThe5555AddressFromTheCachedWifiIp_whenOffline()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);
        cfg.SetDevice("wifi-only", new DeviceCache { Alias = "W 老设备", WifiIp = "192.0.2.61" });

        WebRow row = WebRows.Build(new List<DeviceRow>(), cfg).Single();

        Assert.Equal("192.0.2.61:5555", row.Addr);
        Assert.Equal(new List<string> { "TCP" }, row.Conn);
        Assert.True(row.Offline);
    }

    [Fact]
    public void Build_listsCachedDevicesAsOfflineAndSortsOnlineFirst()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);
        cfg.SetDevice("old-pad", new DeviceCache { Alias = "Z 旧平板", Model = "M", TlsLast = "adb-old-_adb-tls-connect._tcp", WifiIp = "203.0.113.7" });
        cfg.SetDevice("old-phone", new DeviceCache { DevName = "A 旧手机", Model = "M", KnownUsb = true });

        DeviceRow live = Online("live");
        live.DevName = "M 在线机";

        List<WebRow> rows = WebRows.Build(new List<DeviceRow> { live }, cfg);

        Assert.Equal(3, rows.Count);
        // 在线的排最前，离线的按名字排；离线行置灰但保留地址，用户才知道怎么再连回来
        Assert.Equal(new List<string> { "M 在线机", "A 旧手机", "Z 旧平板" }, rows.Select(r => r.Name).ToList());

        WebRow pad = rows.Single(r => r.Key == "old-pad");
        Assert.True(pad.Offline);
        Assert.False(pad.Online);
        Assert.Equal("adb-old-_adb-tls-connect._tcp", pad.Addr);
        Assert.Equal(new List<string> { "TLS", "TCP" }, pad.Conn);
        Assert.Equal(string.Empty, pad.BatteryText);

        WebRow phone = rows.Single(r => r.Key == "old-phone");
        Assert.Equal(new List<string> { "USB" }, phone.Conn);
        Assert.Equal(string.Empty, phone.Addr);
    }

    [Fact]
    public void Build_remembersTheEndpointsItJustSaw()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);

        DeviceRow r = Online("c1e5d47a");
        r.Usb = true;
        r.Tls = "adb-x-_adb-tls-connect._tcp";

        WebRows.Build(new List<DeviceRow> { r }, cfg);

        // 掉线后这一行还能显示上次的无线地址，靠的就是这次回写
        DeviceCache c = cfg.Device("c1e5d47a");
        Assert.Equal("adb-x-_adb-tls-connect._tcp", c.TlsLast);
        Assert.True(c.KnownUsb);
    }

    [Fact]
    public void Build_doesNotOverwriteHistoryWithAnEmptyChannel()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);
        cfg.SetDevice("c1e5d47a", new DeviceCache { TlsLast = "adb-old-_adb-tls-connect._tcp", KnownUsb = true });

        DeviceRow r = Online("c1e5d47a");   // 这一次只有 USB，没有无线
        r.Usb = true;

        WebRows.Build(new List<DeviceRow> { r }, cfg);

        Assert.Equal("adb-old-_adb-tls-connect._tcp", cfg.Device("c1e5d47a").TlsLast);
        Assert.True(cfg.Device("c1e5d47a").KnownUsb);
    }

    [Fact]
    public void ConnText_andBatteryText_stayEmptyWhenThereIsNothingToShow()
    {
        using var tmp = new TempDir();
        var cfg = new ConfigService(tmp.Path);

        WebRow row = WebRows.Build(new List<DeviceRow> { new() { Key = "bare" } }, cfg).Single();

        Assert.Empty(row.Conn);
        Assert.Equal(string.Empty, row.ConnText);
        Assert.Equal(string.Empty, row.BatteryText);
        Assert.Equal("bare", row.Name);
    }
}
