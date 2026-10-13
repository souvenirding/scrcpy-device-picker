using System.Text.Json.Serialization;

namespace ScrcpyPicker.Models;

/// <summary>
/// 单台设备的缓存条目。JSON 键沿用 PowerShell / Go / Swift 版，
/// 老配置文件（%APPDATA%\ScrcpyPicker\devices.json）直接就能读，不做迁移。
/// 用 record 是为了"取出来就是一份不可变副本"，跨线程传值不用担心被人偷偷改了。
/// </summary>
public sealed record DeviceCache
{
    [JsonPropertyName("ts")] public string Ts { get; init; } = string.Empty;
    [JsonPropertyName("Model")] public string Model { get; init; } = string.Empty;
    [JsonPropertyName("Device")] public string Device { get; init; } = string.Empty;
    [JsonPropertyName("Android")] public string Android { get; init; } = string.Empty;
    [JsonPropertyName("Brand")] public string Brand { get; init; } = string.Empty;
    [JsonPropertyName("DevName")] public string DevName { get; init; } = string.Empty;
    [JsonPropertyName("WifiIp")] public string WifiIp { get; init; } = string.Empty;
    [JsonPropertyName("Battery")] public string Battery { get; init; } = string.Empty;
    [JsonPropertyName("Charging")] public string Charging { get; init; } = string.Empty;
    [JsonPropertyName("Alias")] public string Alias { get; init; } = string.Empty;
    [JsonPropertyName("TlsLast")] public string TlsLast { get; init; } = string.Empty;
    [JsonPropertyName("KnownUsb")] public bool KnownUsb { get; init; }
}

/// <summary>全局设置。</summary>
public sealed record PickerSettings
{
    [JsonPropertyName("preferUsb")] public bool PreferUsb { get; init; } = true;
    [JsonPropertyName("scanSubnet")] public bool ScanSubnet { get; init; } = true;

    /// <summary>投屏时是否挂吸附式导航条。默认开：老文件里没这个键，读出来就是 true。</summary>
    [JsonPropertyName("navBar")] public bool NavBar { get; init; } = true;

    /// <summary>用户指定 / 自动搜索命中后记住的 adb+scrcpy 目录；空表示没记过。</summary>
    [JsonPropertyName("toolDir")] public string ToolDir { get; init; } = string.Empty;
}

/// <summary>整个配置文件（devices.json）。</summary>
public sealed record PickerConfig
{
    [JsonPropertyName("devices")] public Dictionary<string, DeviceCache> Devices { get; init; } = new();
    [JsonPropertyName("settings")] public PickerSettings Settings { get; init; } = new();
}

/// <summary>
/// 一次 adb shell 往返取到的设备详情（对应 Go 的 discovery.DeviceDetail）。
/// </summary>
public sealed record DeviceDetail
{
    public string SerialNo { get; init; } = string.Empty;
    public string Model { get; init; } = string.Empty;
    public string Device { get; init; } = string.Empty;
    public string Android { get; init; } = string.Empty;
    public string Brand { get; init; } = string.Empty;
    public string DevName { get; init; } = string.Empty;
    public string Battery { get; init; } = string.Empty;
    public string Charging { get; init; } = string.Empty;
    public string WifiIp { get; init; } = string.Empty;
}

/// <summary>adb 列出的一条传输。</summary>
public enum TransportKind
{
    Usb,
    Tls,
    Tcp5555,
}

/// <summary>一条 adb 传输记录（传输名 + 从 -l 输出里抠出来的型号）。</summary>
public sealed record Transport
{
    public string Serial { get; init; } = string.Empty;
    public string Model { get; init; } = string.Empty;
    public string Product { get; init; } = string.Empty;
    public TransportKind Kind { get; init; } = TransportKind.Usb;
}

/// <summary>
/// 一台设备的聚合行（服务层内部结构，字段与 Go 的 discovery.DeviceRow 一致）。
/// 注意 Key 可能被"真实串号"替换过，所以它不一定能直接当 adb -s 的参数用。
/// </summary>
public sealed class DeviceRow
{
    public string Key { get; set; } = string.Empty;
    public string Alias { get; set; } = string.Empty;
    public string Model { get; set; } = string.Empty;
    public string Device { get; set; } = string.Empty;
    public string Android { get; set; } = string.Empty;
    public string Brand { get; set; } = string.Empty;
    public string DevName { get; set; } = string.Empty;
    public string Battery { get; set; } = string.Empty;
    public string Charging { get; set; } = string.Empty;
    public string WifiIp { get; set; } = string.Empty;
    public bool Usb { get; set; }
    public string UsbSerial { get; set; } = string.Empty;
    public string Tls { get; set; } = string.Empty;
    public string Tcp5555 { get; set; } = string.Empty;
    public bool Online { get; set; }
    public string Preferred { get; set; } = string.Empty;
    public string Connection { get; set; } = string.Empty;
}
