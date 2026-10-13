using System.IO;
using System.Text;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.Tests;

/// <summary>
/// devices.json 读写。键名必须和 PowerShell / Go / Swift 版一致，
/// 老文件直接能读——这条契约只能在测试里钉住，不然改个属性名就把用户的缓存清了。
/// </summary>
[Collection(EnvCollectionDefinition.Name)]
public class ConfigServiceTests
{
    [Fact]
    public void SettingsAndToolDir_surviveAReload()
    {
        using var tmp = new TempDir();
        var first = new ConfigService(tmp.Path);
        Assert.True(first.Settings().PreferUsb);   // 默认 USB 优先
        Assert.True(first.Settings().ScanSubnet);
        Assert.Equal(string.Empty, first.ToolDir());

        first.SetPreferUsb(false);
        first.SetToolDir(@"E:\Flash\tools\scrcpy");

        var again = new ConfigService(tmp.Path);
        Assert.False(again.Settings().PreferUsb);
        Assert.True(again.Settings().ScanSubnet);
        Assert.Equal(@"E:\Flash\tools\scrcpy", again.ToolDir());
    }

    [Fact]
    public void DeviceEntries_roundTrip_andCanBeRemoved()
    {
        using var tmp = new TempDir();
        var svc = new ConfigService(tmp.Path);

        svc.SetDevice("c1e5d47a", new DeviceCache
        {
            Model = "Mi 10 Pro",
            DevName = "小米 10 Pro",
            Alias = "主力机",
            TlsLast = "adb-x-_adb-tls-connect._tcp",
            KnownUsb = true,
            Ts = "2026-10-11T15:00:00.0000000+08:00",
        });

        var reloaded = new ConfigService(tmp.Path);
        Assert.True(reloaded.TryGetDevice("c1e5d47a", out DeviceCache got));
        Assert.Equal("Mi 10 Pro", got.Model);
        Assert.Equal("主力机", got.Alias);
        Assert.Equal("adb-x-_adb-tls-connect._tcp", got.TlsLast);
        Assert.True(got.KnownUsb);

        reloaded.RemoveDevice("c1e5d47a");
        Assert.False(new ConfigService(tmp.Path).TryGetDevice("c1e5d47a", out _));
    }

    [Fact]
    public void UnknownDevice_readsAsAnEmptyEntry_notAnException()
    {
        using var tmp = new TempDir();
        var svc = new ConfigService(tmp.Path);

        DeviceCache c = svc.Device("never-seen");
        Assert.Equal(string.Empty, c.Model);
        Assert.False(c.KnownUsb);
    }

    [Fact]
    public void LegacyFile_fromTheGoVersion_isReadableVerbatim()
    {
        using var tmp = new TempDir();
        // 这份 JSON 是 Go / PowerShell 版的落盘形状（大小写混用的键名），手写成文本来钉住契约。
        string legacy = """
            {
              "devices": {
                "a1b2c3": {
                  "ts": "2026-10-01T08:00:00+08:00",
                  "Model": "Sample_Model_A",
                  "Device": "samplea",
                  "Android": "13",
                  "Brand": "Xiaomi",
                  "DevName": "小米平板 6",
                  "WifiIp": "192.0.2.61",
                  "Battery": "66",
                  "Charging": "放电",
                  "Alias": "平板",
                  "TlsLast": "adb-a1b2c3-_adb-tls-connect._tcp",
                  "KnownUsb": true
                }
              },
              "settings": {
                "preferUsb": false,
                "scanSubnet": true,
                "toolDir": "E:\\Flash\\tools\\scrcpy"
              }
            }
            """;
        File.WriteAllText(Path.Combine(tmp.Path, "devices.json"), legacy, new UTF8Encoding(false));

        var svc = new ConfigService(tmp.Path);
        Assert.False(svc.Settings().PreferUsb);
        Assert.Equal(@"E:\Flash\tools\scrcpy", svc.ToolDir());
        Assert.True(svc.TryGetDevice("a1b2c3", out DeviceCache c));
        Assert.Equal("小米平板 6", c.DevName);
        Assert.Equal("66", c.Battery);
        Assert.Equal("adb-a1b2c3-_adb-tls-connect._tcp", c.TlsLast);
    }

    [Fact]
    public void MissingSections_fallBackToDefaults()
    {
        using var tmp = new TempDir();
        File.WriteAllText(Path.Combine(tmp.Path, "devices.json"), "{}");

        var svc = new ConfigService(tmp.Path);
        Assert.Empty(svc.Snapshot().Devices);
        Assert.True(svc.Settings().PreferUsb);
    }

    [Fact]
    public void CorruptFile_isTreatedAsEmpty_andTheNextWriteRepairsIt()
    {
        using var tmp = new TempDir();
        string file = Path.Combine(tmp.Path, "devices.json");
        File.WriteAllText(file, "{ this is not json");

        var svc = new ConfigService(tmp.Path);
        Assert.Empty(svc.Snapshot().Devices);

        svc.SetPreferUsb(false);
        Assert.False(new ConfigService(tmp.Path).Settings().PreferUsb);
    }

    [Fact]
    public void SavedFile_keepsChineseReadable_andLeavesNoTempFile()
    {
        using var tmp = new TempDir();
        var svc = new ConfigService(tmp.Path);
        svc.SetDevice("x1", new DeviceCache { DevName = "小米平板" });

        string text = File.ReadAllText(svc.FilePath);
        // 宽松转义：中文按原样写出去，和 Go 版产物一致；别变成一串 \uXXXX
        Assert.True(text.Contains("小米平板", StringComparison.Ordinal));
        Assert.False(text.Contains("\\u", StringComparison.Ordinal));
        Assert.False(File.Exists(svc.FilePath + ".tmp"));
    }

    [Fact]
    public void Snapshot_isACopy_soCallersCannotMutateTheCache()
    {
        using var tmp = new TempDir();
        var svc = new ConfigService(tmp.Path);
        svc.SetDevice("keep", new DeviceCache { Model = "m" });

        PickerConfig snap = svc.Snapshot();
        snap.Devices.Clear();

        Assert.True(svc.TryGetDevice("keep", out _));
    }

    [Fact]
    public void ConfigDir_prefersScrcpyConfigDirOverAppData()
    {
        using var tmp = new TempDir();
        using (Env.Set("SCRCPY_CONFIG_DIR", tmp.Path))
        {
            Assert.Equal(tmp.Path, ConfigService.ConfigDir());
        }
        // 环境变量撤掉后回到 %APPDATA%\ScrcpyPicker——界面和自检测共用这一个落点
        string fallback = ConfigService.ConfigDir();
        Assert.EndsWith("ScrcpyPicker", fallback);
        Assert.NotEqual(tmp.Path, fallback);
    }
}
