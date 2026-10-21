using ScrcpyPicker.Services;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 无线发现的纯解析层：adb mdns services 的文本来自真机，格式细节
/// （服务类型、制表符、mDNS 实例名里的串号提示）都在这里钉死，不依赖网络。
/// </summary>
public class WirelessDiscoveryTests
{
    [Fact]
    public void ParseMdnsServices_keepsConnectService_andExtractsSerialHint()
    {
        string[] lines =
        {
            "List of discovered mdns services",
            "adb-b0779a03-dyhXNo\t_adb-tls-connect._tcp\t192.168.123.92:39541",
        };

        List<MdnsService> got = DiscoveryService.ParseMdnsServices(lines);

        MdnsService svc = Assert.Single(got);
        Assert.Equal("adb-b0779a03-dyhXNo", svc.Name);
        Assert.Equal("192.168.123.92:39541", svc.Endpoint);
        // 串号提示来自 "adb-<串号>-<随机码>"，注意随机码之前的串号本身可以带连字符。
        Assert.Equal("b0779a03", svc.SerialHint);
        Assert.Equal("adb-b0779a03-dyhXNo._adb-tls-connect._tcp", svc.TransportName);
    }

    [Fact]
    public void ParseMdnsServices_ignoresPairingAndOtherServices()
    {
        string[] lines =
        {
            "List of discovered mdns services",
            "adb-b0779a03-dyhXNo\t_adb-tls-pairing._tcp\t192.168.123.92:41001",
            "printer\t_ipp._tcp\t192.168.123.50:631",
            "adb-other-ABC123\t_adb-tls-connect._tcp\t192.168.123.93:37000",
        };

        List<MdnsService> got = DiscoveryService.ParseMdnsServices(lines);

        MdnsService svc = Assert.Single(got);
        Assert.Equal("192.168.123.93:37000", svc.Endpoint);
        Assert.Equal("other", svc.SerialHint);
    }

    [Fact]
    public void ParseMdnsServices_deduplicatesEndpoints_andSkipsMalformedLines()
    {
        string[] lines =
        {
            "adb-a-AAAAA\t_adb-tls-connect._tcp\t192.168.1.10:40000",
            "adb-a-BBBBB\t_adb-tls-connect._tcp\t192.168.1.10:40000",
            "adb-no-endpoint\t_adb-tls-connect._tcp",
            "adb-bad-endpoint\t_adb-tls-connect._tcp\tnot-an-endpoint",
        };

        List<MdnsService> got = DiscoveryService.ParseMdnsServices(lines);

        Assert.Single(got);
        Assert.Equal("a", got[0].SerialHint);
    }

    [Fact]
    public void ParseMdnsServices_acceptsFullServiceName_andEmptyOutput()
    {
        List<MdnsService> got = DiscoveryService.ParseMdnsServices(new[]
        {
            "adb-ZJ5T7NL8-MY\t_adb-tls-connect._tcp\t192.0.2.50:43210",
        });

        // 随机码只有 2 个字符时不符合 adb 的命名规则，宁可不猜串号，也不能拿错 Key 去建行。
        Assert.Equal(string.Empty, got[0].SerialHint);
        Assert.Equal("adb-ZJ5T7NL8-MY._adb-tls-connect._tcp", got[0].TransportName);

        Assert.Empty(DiscoveryService.ParseMdnsServices(Array.Empty<string>()));
        Assert.Empty(DiscoveryService.ParseMdnsServices(new[] { "List of discovered mdns services" }));
    }
}
