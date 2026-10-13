using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>
/// 在线设备 + 历史缓存组装成界面要的一行（对应 Go 的 internal/webrows）。
/// 字段语义与旧前端 app.js 读的完全一致，改动前先看界面哪里在用。
/// </summary>
public sealed class WebRow
{
    public string Key { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string Model { get; init; } = string.Empty;
    public string Device { get; init; } = string.Empty;
    public string Android { get; init; } = string.Empty;

    /// <summary>机器可读的连接标记：USB / TLS / TCP。中文标签由界面层加。</summary>
    public List<string> Conn { get; init; } = new();

    public string Addr { get; init; } = string.Empty;
    public string Battery { get; init; } = string.Empty;
    public string Charging { get; init; } = string.Empty;
    public bool Online { get; init; }
    public bool Offline { get; init; }
    public string Preferred { get; init; } = string.Empty;
    public bool Usb { get; init; }
    public string UsbSerial { get; init; } = string.Empty;
    public string Tls { get; init; } = string.Empty;
    public string Tcp5555 { get; init; } = string.Empty;

    /// <summary>界面用的连接描述（"USB + 无线调试"）。</summary>
    public string ConnText => string.Join("  +  ", Conn.Select(c => c switch
    {
        "USB" => "USB",
        "TLS" => "无线调试",
        "TCP" => "TCP 5555",
        _ => c,
    }));

    /// <summary>界面用的电量描述。</summary>
    public string BatteryText => Battery.Length > 0 ? $"{Battery}% {Charging}".Trim() : string.Empty;
}

/// <summary>把 DeviceRow 列表加工成界面行列表（含离线设备，按名称排序、在线优先）。</summary>
public static class WebRows
{
    public static List<WebRow> Build(List<DeviceRow> online, ConfigService cfg)
    {
        PickerConfig snapshot = cfg.Snapshot();
        var rows = new List<WebRow>();
        var seen = new HashSet<string>();

        foreach (DeviceRow o in online)
        {
            string alias = snapshot.Devices.TryGetValue(o.Key, out var c0) ? c0.Alias : string.Empty;
            string name = FirstNonEmpty(alias, o.DevName, o.Model, o.Key);

            var conn = new List<string>();
            if (o.Usb) conn.Add("USB");
            if (o.Tls.Length > 0) conn.Add("TLS");
            if (o.Tcp5555.Length > 0) conn.Add("TCP");

            string addr = FirstNonEmpty(o.Tls, o.Tcp5555, o.WifiIp);

            rows.Add(new WebRow
            {
                Key = o.Key,
                Name = name,
                Model = o.Model,
                Device = o.Device,
                Android = o.Android,
                Conn = conn,
                Addr = addr,
                Battery = o.Battery,
                Charging = o.Charging,
                Online = true,
                Offline = false,
                Preferred = o.Preferred,
                Usb = o.Usb,
                UsbSerial = o.UsbSerial,
                Tls = o.Tls,
                Tcp5555 = o.Tcp5555,
            });
            seen.Add(o.Key);
        }

        // 之前见过的设备继续列出，但标记为离线（界面置灰）。
        foreach ((string k, DeviceCache c) in snapshot.Devices)
        {
            if (seen.Contains(k)) continue;
            string name = FirstNonEmpty(c.Alias, c.DevName, c.Model, k);

            var conn = new List<string>();
            if (c.KnownUsb) conn.Add("USB");
            if (c.TlsLast.Length > 0) conn.Add("TLS");
            if (c.WifiIp.Length > 0) conn.Add("TCP");

            string addr = c.TlsLast.Length > 0 ? c.TlsLast
                : c.WifiIp.Length > 0 ? c.WifiIp + ":5555"
                : string.Empty;

            rows.Add(new WebRow
            {
                Key = k,
                Name = name,
                Model = c.Model,
                Device = c.Device,
                Android = c.Android,
                Conn = conn,
                Addr = addr,
                Battery = string.Empty,
                Charging = string.Empty,
                Online = false,
                Offline = true,
                Preferred = string.Empty,
                Usb = false,
                UsbSerial = string.Empty,
                Tls = string.Empty,
                Tcp5555 = string.Empty,
            });
        }

        // 记住上次见到的端点，离线行才能继续显示地址。
        foreach (DeviceRow o in online)
        {
            DeviceCache c = cfg.Device(o.Key);
            var next = c with
            {
                TlsLast = o.Tls.Length > 0 ? o.Tls : c.TlsLast,
                KnownUsb = o.Usb || c.KnownUsb,
            };
            if (next != c) cfg.SetDevice(o.Key, next);
        }

        // 在线优先，其次按名称（OrderBy 是稳定排序，与 Go 的 SliceStable 等价）。
        return rows.OrderBy(r => r.Offline).ThenBy(r => r.Name, StringComparer.Ordinal).ToList();
    }

    private static string FirstNonEmpty(params string[] vals)
    {
        foreach (string v in vals) if (v.Length > 0) return v;
        return string.Empty;
    }
}
