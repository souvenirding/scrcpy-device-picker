using System.Text.RegularExpressions;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>
/// 设备发现核心（移植自 Go 版 internal/discovery，源头是 shared/Discover.ps1）。
///
/// 分类规则是上一轮修 bug 的关键，必须逐条照搬：
///   * 以 "_adb-tls-connect._tcp" 结尾  -> 无线调试(TLS)
///   * "ip:5555"                        -> 传统 adbd(TCP)
///   * "ip:&lt;其他端口&gt;"                 -> TLS
///   * 其余                              -> USB
/// 绝不能用"串号里没有冒号就是 USB"来判断：mDNS 服务名里根本没有冒号。
/// </summary>
public sealed class DiscoveryService
{
    private static readonly Regex DeviceLineRe = new(@"^(\S+)\s+device\b", Rx());
    private static readonly Regex ModelRe = new(@"model:(\S+)", Rx());
    private static readonly Regex ProductRe = new(@"product:(\S+)", Rx());
    private static readonly Regex TlsNameRe = new(@"_adb-tls-connect\._tcp$", Rx());
    private static readonly Regex IpPortRe = new(@"^(\d+\.\d+\.\d+\.\d+):(\d+)$", Rx());
    private static readonly Regex SectionRe = new(@"^MK_S(\d)$", Rx());
    private static readonly Regex LevelRe = new(@"^\s*level:\s*(\d+)", Rx());
    private static readonly Regex StatusRe = new(@"^\s*status:\s*(\d+)", Rx());
    private static readonly Regex InetRe = new(@"inet\s+([0-9]+(?:\.[0-9]+){3})", Rx());

    private static RegexOptions Rx() =>
        RegexOptions.CultureInvariant | RegexOptions.Compiled;

    /// <summary>详情缓存的新鲜期：1 分钟内的 getprop 结果直接复用，免得每 10 秒敲一次手机。</summary>
    private static readonly TimeSpan DetailTtl = TimeSpan.FromSeconds(60);

    private readonly ToolchainHolder _tools;
    private readonly ConfigService _cfg;
    private readonly object _gate = new();

    /// <summary>
    /// 传输名 -> 真实串号。无线调试下两者不同（传输名是 mDNS 服务名），
    /// 而备注名/详情缓存按真实串号存；不记这层映射，每次刷新都会拿一个"查不到的 Key"
    /// 去读缓存，于是备注名被空值覆盖、getprop 每 10 秒重跑一次。
    /// </summary>
    private readonly Dictionary<string, string> _knownSerial = new();

    public DiscoveryService(ToolchainHolder tools, ConfigService cfg)
    {
        _tools = tools;
        _cfg = cfg;
    }

    /// <summary>取当前工具链快照；用户改了 adb 目录后这里立刻拿到新的一份。</summary>
    private ToolchainSnapshot Tc() => _tools.Get();

    public string SerialOf(string transport)
    {
        lock (_gate) return _knownSerial.TryGetValue(transport, out var s) ? s : transport;
    }

    public void Remember(string transport, string serial)
    {
        lock (_gate) _knownSerial[transport] = serial;
    }

    /// <summary>解析 "adb devices -l" 并按形状分类。</summary>
    public List<Transport> UsbTransports() =>
        ParseDeviceList(ToolchainService.Adb(Tc(), new[] { "devices", "-l" }));

    /// <summary>
    /// 纯解析：把 "adb devices -l" 的输出变成传输列表。
    /// 拆出来是为了没真机也能回归测试 —— 分类规则是这块最容易写错的地方。
    /// </summary>
    public static List<Transport> ParseDeviceList(string[] lines)
    {
        var res = new List<Transport>();
        foreach (string line in lines)
        {
            var g = DeviceLineRe.Match(line);
            if (!g.Success) continue;
            string serial = g.Groups[1].Value;

            var m = ModelRe.Match(line);
            var p = ProductRe.Match(line);

            res.Add(new Transport
            {
                Serial = serial,
                Model = m.Success ? m.Groups[1].Value : string.Empty,
                Product = p.Success ? p.Groups[1].Value : string.Empty,
                Kind = ClassifyTransport(serial),
            });
        }
        return res;
    }

    /// <summary>
    /// 传输名的形状决定通道：以 _adb-tls-connect._tcp 结尾的是 adb 自己发现的无线调试；
    /// ip:5555 是老的 adb tcpip 模式；其余 ip:port 仍按无线调试（随机端口）算；
    /// 其它（纯串号）才是 USB。
    /// </summary>
    public static TransportKind ClassifyTransport(string serial)
    {
        if (TlsNameRe.IsMatch(serial)) return TransportKind.Tls;
        var ip = IpPortRe.Match(serial);
        if (!ip.Success) return TransportKind.Usb;
        return ip.Groups[2].Value == "5555" ? TransportKind.Tcp5555 : TransportKind.Tls;
    }

    /// <summary>adb 当前列出的 serial -> state（device / offline / unauthorized…）。</summary>
    public Dictionary<string, string> LiveTransports() =>
        ParseDeviceStates(ToolchainService.Adb(Tc(), new[] { "devices" }));

    /// <summary>纯解析：adb devices（不带 -l）的输出 → 状态表。</summary>
    public static Dictionary<string, string> ParseDeviceStates(string[] lines)
    {
        var map = new Dictionary<string, string>();
        foreach (string line in lines)
        {
            string[] fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2) continue;
            map[fields[0]] = fields[1];
        }
        return map;
    }

    /// <summary>
    /// 在所有候选里挑一个 adb 当前真的列为 device 的；一个都没有时退回首选，
    /// 好让 scrcpy / adb 自己报出真正的错误，而不是静默失败。
    /// </summary>
    public string ResolveTarget(string key, string preferred, string usbSerial, string tls, string tcp5555) =>
        ChooseTarget(CandidateTargets(key, preferred, usbSerial, tls, tcp5555), LiveTransports());

    /// <summary>候选顺序：首选 → USB → 无线调试 → TCP 5555 → Key 本身；去空、去重、保序。</summary>
    public static List<string> CandidateTargets(string key, string preferred, string usbSerial, string tls, string tcp5555)
    {
        var cands = new List<string>();
        void Add(string c)
        {
            if (string.IsNullOrEmpty(c)) return;
            if (!cands.Contains(c)) cands.Add(c);
        }
        Add(preferred);
        Add(usbSerial);
        Add(tls);
        Add(tcp5555);
        Add(key);
        return cands;
    }

    /// <summary>纯选择：第一个被 adb 现役列为 device 的候选，全都不可用就退回首选。</summary>
    public static string ChooseTarget(List<string> cands, Dictionary<string, string> live)
    {
        foreach (string c in cands)
        {
            if (live.TryGetValue(c, out string? st) && st == "device") return c;
        }
        return cands.Count > 0 ? cands[0] : string.Empty;
    }

    /// <summary>一次 shell 往返取详情，用哨兵分段（一次 adb 调用拿全部字段）。</summary>
    public DeviceDetail? ReadDetail(string serial)
    {
        string cmd = "echo MK_S1; getprop ro.serialno; echo MK_S2; getprop ro.product.model; echo MK_S3; " +
            "getprop ro.product.device; echo MK_S4; getprop ro.build.version.release; echo MK_S5; " +
            "getprop ro.product.brand; echo MK_S6; settings get global device_name; echo MK_S7; " +
            "ip -4 addr show wlan0; echo MK_S8; dumpsys battery";

        return ParseDetail(ToolchainService.Adb(Tc(), new[] { "-s", serial, "shell", cmd }));
    }

    /// <summary>
    /// 纯解析：哨兵分段 → 设备详情。
    /// 拿不到型号（第 2 段）就判定无效：多半是设备刚掉线或还没授权。
    /// </summary>
    public static DeviceDetail? ParseDetail(string[] lines)
    {
        var sections = new Dictionary<string, List<string>>();
        string current = string.Empty;

        foreach (string raw in lines)
        {
            string ln = raw.TrimEnd('\r');
            var g = SectionRe.Match(ln);
            if (g.Success)
            {
                current = g.Groups[1].Value;
                sections[current] = new List<string>();
                continue;
            }
            if (current.Length > 0)
            {
                if (!sections.TryGetValue(current, out var bucket))
                {
                    bucket = new List<string>();
                    sections[current] = bucket;
                }
                bucket.Add(ln.Trim());
            }
        }

        // 拿不到型号就视为无效：多半是设备刚掉线或还没授权。
        if (!sections.ContainsKey("2")) return null;

        string Sec(string n)
        {
            if (!sections.TryGetValue(n, out var v) || v.Count == 0) return string.Empty;
            string first = v[0];
            return first is "" or "null" ? string.Empty : first;
        }

        string battery = string.Empty, charging = string.Empty, wifiIp = string.Empty;
        var wifiAndBattery = new List<string>();
        if (sections.TryGetValue("7", out var s7)) wifiAndBattery.AddRange(s7);
        if (sections.TryGetValue("8", out var s8)) wifiAndBattery.AddRange(s8);

        foreach (string v in wifiAndBattery)
        {
            var lm = LevelRe.Match(v);
            if (lm.Success)
            {
                battery = lm.Groups[1].Value;
                continue;
            }
            var sm = StatusRe.Match(v);
            if (sm.Success)
            {
                charging = sm.Groups[1].Value switch
                {
                    "2" => "充电中",
                    "3" => "放电",
                    "4" => "已充满",
                    _ => charging,
                };
                continue;
            }
            var im = InetRe.Match(v);
            if (im.Success && wifiIp.Length == 0) wifiIp = im.Groups[1].Value;
        }

        return new DeviceDetail
        {
            SerialNo = Sec("1"),
            Model = Sec("2"),
            Device = Sec("3"),
            Android = Sec("4"),
            Brand = Sec("5"),
            DevName = Sec("6"),
            Battery = battery,
            Charging = charging,
            WifiIp = wifiIp,
        };
    }

    /// <summary>
    /// 合并在线设备清单。deep=false 时优先用 1 分钟内的详情缓存；
    /// allowWireless 目前不进 adb 调用，只是保留与 Go 版一致的签名（无线通道由 adb 的 mDNS 自己发现）。
    /// </summary>
    public List<DeviceRow> Inventory(bool deep, bool allowWireless)
    {
        PickerConfig cfg = _cfg.Snapshot();
        bool preferUsb = cfg.Settings.PreferUsb;

        var rows = new Dictionary<string, DeviceRow>();

        foreach (var u in UsbTransports())
        {
            string transport = u.Serial;
            string key = SerialOf(transport);
            if (!rows.TryGetValue(key, out var r))
            {
                r = new DeviceRow { Key = key };
                rows[key] = r;
            }
            r.Model = u.Model;
            switch (u.Kind)
            {
                case TransportKind.Usb:
                    r.Usb = true;
                    // UsbSerial 恒为 adb 认的字面传输名；Key 稍后可能被真实串号替换，
                    // 所以 Key 永远不能直接当 -s 的参数用。
                    r.UsbSerial = transport;
                    break;
                case TransportKind.Tls:
                    r.Tls = transport;
                    break;
                case TransportKind.Tcp5555:
                    r.Tcp5555 = transport;
                    break;
            }
            r.Online = true;
        }

        foreach (string key in rows.Keys.ToList())
        {
            if (!rows.TryGetValue(key, out var r)) continue; // 上一轮已被真实串号顶掉

            DeviceCache cache = _cfg.Device(key);
            bool stale = true;
            if (!deep && cache.Ts.Length > 0 && cache.Model.Length > 0 &&
                DateTimeOffset.TryParse(cache.Ts, System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.RoundtripKind, out var ts))
            {
                if (DateTimeOffset.UtcNow - ts <= DetailTtl) stale = false;
            }

            if (stale)
            {
                string probe = r.Usb && r.UsbSerial.Length > 0 ? r.UsbSerial
                    : r.Tls.Length > 0 ? r.Tls
                    : r.Tcp5555.Length > 0 ? r.Tcp5555
                    : key;

                var det = ReadDetail(probe);
                if (det is not null)
                {
                    string finalSerial = det.SerialNo.Length > 0 ? det.SerialNo : probe;
                    Remember(probe, finalSerial);

                    // 备注名可能挂在旧 Key（传输名）上，也可能已经挂在真实串号上。
                    string alias = _cfg.Device(finalSerial).Alias;
                    if (alias.Length == 0) alias = cache.Alias;

                    var next = new DeviceCache
                    {
                        Ts = DateTimeOffset.UtcNow.ToString("O"),
                        Model = det.Model,
                        Device = det.Device,
                        Android = det.Android,
                        Brand = det.Brand,
                        DevName = det.DevName,
                        WifiIp = det.WifiIp,
                        Battery = det.Battery,
                        Charging = det.Charging,
                        Alias = alias,
                    };

                    if (finalSerial != key)
                    {
                        // 详情暴露出：我们临时用的 key 并不是真实串号。
                        rows.Remove(key);
                        r.Key = finalSerial;
                        rows[finalSerial] = r;
                        _cfg.RemoveDevice(key);
                    }
                    _cfg.SetDevice(finalSerial, next);
                }
            }

            // 用最新缓存回填展示字段（含备注名）
            if (_cfg.TryGetDevice(r.Key, out var fresh))
            {
                r.Model = fresh.Model;
                r.Device = fresh.Device;
                r.Android = fresh.Android;
                r.Brand = fresh.Brand;
                r.DevName = fresh.DevName;
                r.WifiIp = fresh.WifiIp;
                r.Alias = fresh.Alias;
                r.Battery = fresh.Battery;
                r.Charging = fresh.Charging;
            }

            string usbHandle = string.Empty;
            if (r.Usb && r.UsbSerial.Length > 0) usbHandle = r.UsbSerial;
            else if (r.Usb) usbHandle = r.Key;

            r.Preferred = preferUsb
                ? FirstNonEmpty(usbHandle, r.Tls, r.Tcp5555)
                : FirstNonEmpty(r.Tls, r.Tcp5555, usbHandle);

            var conns = new List<string>();
            if (r.Usb) conns.Add("USB");
            if (r.Tls.Length > 0) conns.Add("无线调试");
            if (r.Tcp5555.Length > 0) conns.Add("TCP 5555");
            r.Connection = string.Join(" + ", conns);
        }

        return rows.Values.ToList();
    }

    /// <summary>断开一个无线端点（仅当含冒号，避免误杀 USB）。</summary>
    public void Disconnect(string endpoint)
    {
        if (!endpoint.Contains(':')) return;
        ToolchainService.Adb(Tc(), new[] { "disconnect", endpoint });
    }

    private static string FirstNonEmpty(params string[] vals)
    {
        foreach (string v in vals) if (v.Length > 0) return v;
        return string.Empty;
    }
}
