using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>
/// 一条 mDNS 广播（adb mdns services 的输出行）。
/// Name 是服务实例名（adb-&lt;串号&gt;-&lt;hash&gt;），TransportName 补上服务类型后缀后
/// 与 adb devices 里列出的传输名一致。
/// </summary>
public sealed record MdnsService(string Name, string Endpoint, string SerialHint)
{
    public const string ServiceType = "_adb-tls-connect._tcp";

    public string TransportName =>
        Name.EndsWith(ServiceType, StringComparison.Ordinal) ? Name : Name + "." + ServiceType;
}

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
    private static readonly Regex MdnsSerialRe = new(@"^adb-(.+)-[A-Za-z0-9]{5,}$", Rx());
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

    /// <summary>
    /// 连不上的无线端点退避 30 秒：mDNS 广播和手写的 5555 地址都可能指向已经换了端口
    /// 或已经关机的端点，每 10 秒刷新都去等一次 adb connect 的超时会拖慢整个列表。
    /// </summary>
    private readonly Dictionary<string, DateTimeOffset> _connectBackoff = new(StringComparer.Ordinal);
    private static readonly TimeSpan ConnectBackoffTime = TimeSpan.FromSeconds(30);

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

    // ---- 无线发现（mDNS + 子网 5555） ----

    /// <summary>
    /// 纯解析：adb mdns services 的输出 → 可连接的无线调试端点。
    /// 只认 _adb-tls-connect._tcp；_adb-tls-pairing._tcp 是配对窗口，连上去没有意义。
    /// </summary>
    public static List<MdnsService> ParseMdnsServices(string[] lines)
    {
        var result = new List<MdnsService>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (string raw in lines)
        {
            string line = raw.Trim();
            if (line.Length == 0 ||
                !line.Contains(MdnsService.ServiceType, StringComparison.Ordinal)) continue;

            string[] cols = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (cols.Length < 3) continue;

            string name = cols[0];
            string endpoint = cols[^1];
            if (!IpPortRe.IsMatch(endpoint)) continue;
            if (!seen.Add(endpoint)) continue;   // 同一端点重复广播只连一次

            string instance = name.EndsWith(MdnsService.ServiceType, StringComparison.Ordinal)
                ? name[..^MdnsService.ServiceType.Length].TrimEnd('.')
                : name;
            string hint = string.Empty;
            var m = MdnsSerialRe.Match(instance);
            if (m.Success) hint = m.Groups[1].Value;

            result.Add(new MdnsService(instance, endpoint, hint));
        }
        return result;
    }

    /// <summary>
    /// 主动把无线设备接进 adb：每次刷新读一遍 mDNS 广播，深度刷新再扫本机 /24 的 5555。
    /// 只在已经配对/授权过的电脑上有效（配对码不在本工具的职责里）。
    /// </summary>
    private void EnsureWireless(ToolchainSnapshot tc, PickerConfig cfg, bool deep)
    {
        if (!tc.AdbResolved) return;

        List<MdnsService> services =
            ParseMdnsServices(ToolchainService.Adb(tc, new[] { "mdns", "services" }));
        if (services.Count > 0)
        {
            List<Transport> transports = UsbTransports();
            Dictionary<string, string> live = LiveTransports();

            foreach (MdnsService svc in services)
            {
                // mDNS 服务名本身就带着串号提示：先记下，省掉一次“按临时 Key 建行再迁移”。
                if (svc.SerialHint.Length > 0)
                {
                    Remember(svc.TransportName, svc.SerialHint);
                    Remember(svc.Endpoint, svc.SerialHint);
                }

                if (WirelessAlreadyLive(svc, transports, live)) continue;
                if (InConnectBackoff(svc.Endpoint)) continue;

                if (TryConnect(tc, svc.Endpoint))
                {
                    ClearConnectBackoff(svc.Endpoint);
                    ClearDeadTransportsFor(tc, IpOf(svc.Endpoint), svc.Endpoint);
                }
                else
                {
                    MarkConnectBackoff(svc.Endpoint);
                    // connect 失败也会在 adb 里留下 offline 条目，顺手清掉。
                    ToolchainService.Adb(tc, new[] { "disconnect", svc.Endpoint });
                }
            }
        }

        if (!deep || !cfg.Settings.ScanSubnet) return;

        string? prefix = LocalSubnetPrefix(out string ownIp);
        if (prefix is null) return;

        foreach (string ip in ScanTcpPort(prefix, 5555, ownIp))
        {
            string endpoint = ip + ":5555";
            if (InConnectBackoff(endpoint)) continue;
            Dictionary<string, string> live = LiveTransports();
            if (live.TryGetValue(endpoint, out string? state) && state == "device") continue;

            if (TryConnect(tc, endpoint))
            {
                ClearConnectBackoff(endpoint);
                ClearDeadTransportsFor(tc, ip, endpoint);
            }
            else
            {
                MarkConnectBackoff(endpoint);
                ToolchainService.Adb(tc, new[] { "disconnect", endpoint });
            }
        }
    }

    /// <summary>该 mDNS 端点是否已经通过某个传输在线（同串号的 USB 也算，不必再开无线）。</summary>
    private bool WirelessAlreadyLive(
        MdnsService svc, List<Transport> transports, Dictionary<string, string> live)
    {
        if (live.TryGetValue(svc.Endpoint, out string? endpointState) && endpointState == "device")
            return true;
        if (live.TryGetValue(svc.TransportName, out string? mdnsState) && mdnsState == "device")
            return true;
        if (svc.SerialHint.Length == 0) return false;

        foreach (Transport t in transports)
        {
            if (SerialOf(t.Serial) != svc.SerialHint) continue;
            if (live.TryGetValue(t.Serial, out string? state) && state == "device") return true;
        }
        return false;
    }

    /// <summary>
    /// adb connect 返回 "connected" 不代表通道可用：没完成握手的端口会以 offline 挂在
    /// adb devices 里。只有状态真的是 device 才算连上。
    /// </summary>
    private static bool TryConnect(ToolchainSnapshot tc, string endpoint)
    {
        ProcessRunner.Run(tc.AdbPath, new[] { "connect", endpoint }, 6000);
        Dictionary<string, string> live =
            ParseDeviceStates(ToolchainService.Adb(tc, new[] { "devices" }));
        return live.TryGetValue(endpoint, out string? state) && state == "device";
    }

    /// <summary>
    /// 手机换端口后，旧端点会以 offline 永久留在 adb devices 里。
    /// 只清理同一 IP 下的 offline 条目，不碰别的设备。
    /// </summary>
    private void ClearDeadTransportsFor(ToolchainSnapshot tc, string ip, string keepEndpoint)
    {
        if (ip.Length == 0) return;
        string prefix = ip + ":";
        Dictionary<string, string> live = LiveTransports();
        foreach (Transport t in UsbTransports())
        {
            if (t.Serial == keepEndpoint) continue;
            if (!t.Serial.StartsWith(prefix, StringComparison.Ordinal)) continue;
            if (live.TryGetValue(t.Serial, out string? state) && state == "offline")
                ToolchainService.Adb(tc, new[] { "disconnect", t.Serial });
        }
    }

    private static string IpOf(string endpoint)
    {
        int colon = endpoint.LastIndexOf(':');
        return colon > 0 ? endpoint[..colon] : string.Empty;
    }

    private bool InConnectBackoff(string endpoint)
    {
        lock (_gate)
        {
            return _connectBackoff.TryGetValue(endpoint, out DateTimeOffset until) &&
                   until > DateTimeOffset.UtcNow;
        }
    }

    private void MarkConnectBackoff(string endpoint)
    {
        lock (_gate) _connectBackoff[endpoint] = DateTimeOffset.UtcNow + ConnectBackoffTime;
    }

    private void ClearConnectBackoff(string endpoint)
    {
        lock (_gate) _connectBackoff.Remove(endpoint);
    }

    /// <summary>
    /// 用户主动断开无线会话后，这段时间内不要再被 mDNS 自动接回来，
    /// 否则右键「断开无线会话」会在下一轮 10 秒刷新里看起来毫无效果。
    /// </summary>
    public void SuppressWireless(string endpoint, TimeSpan duration)
    {
        if (endpoint.Length == 0) return;
        lock (_gate) _connectBackoff[endpoint] = DateTimeOffset.UtcNow + duration;
    }

    /// <summary>
    /// 取本机用于发现设备的 /24：优先有默认网关的物理网卡（以太网/无线），
    /// 跳过回环、APIPA 与隧道。取不到返回 null，调用方就不扫描。
    /// </summary>
    public static string? LocalSubnetPrefix(out string ownIp)
    {
        ownIp = string.Empty;
        try
        {
            var candidates = new List<(int Rank, string Ip)>();
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback
                    or NetworkInterfaceType.Tunnel) continue;

                IPInterfaceProperties props = nic.GetIPProperties();
                bool hasGateway = props.GatewayAddresses.Any(g =>
                    g.Address.AddressFamily == AddressFamily.InterNetwork &&
                    !g.Address.Equals(IPAddress.Any));
                bool physical = nic.NetworkInterfaceType is NetworkInterfaceType.Ethernet
                    or NetworkInterfaceType.Wireless80211;
                int rank = hasGateway ? (physical ? 0 : 1) : (physical ? 2 : 3);

                foreach (UnicastIPAddressInformation ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    string ip = ua.Address.ToString();
                    if (ip.StartsWith("127.", StringComparison.Ordinal) ||
                        ip.StartsWith("169.254.", StringComparison.Ordinal) ||
                        ip.StartsWith("0.", StringComparison.Ordinal)) continue;
                    candidates.Add((rank, ip));
                }
            }

            var best = candidates.OrderBy(c => c.Rank).FirstOrDefault();
            if (best.Ip is null) return null;
            string[] parts = best.Ip.Split('.');
            if (parts.Length != 4) return null;
            ownIp = best.Ip;
            return string.Join(".", parts.Take(3));
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// 扫 /24 的固定端口：按批发起异步 TCP 连接，每批最多等 timeoutMs。
    /// 默认 64 个一批、400ms 一批，整段 254 个地址约 1.6 秒（只在深度刷新里跑）。
    /// </summary>
    public static List<string> ScanTcpPort(
        string prefix, int port, string skipIp, int timeoutMs = 400, int batchSize = 64)
    {
        var found = new List<string>();
        for (int start = 1; start <= 254; start += batchSize)
        {
            int end = Math.Min(start + batchSize - 1, 254);
            var tries = new List<(string Ip, TcpClient Client, Task Task)>();
            for (int host = start; host <= end; host++)
            {
                string ip = prefix + "." + host;
                if (ip == skipIp) continue;
                var client = new TcpClient();
                try
                {
                    tries.Add((ip, client, client.ConnectAsync(ip, port)));
                }
                catch
                {
                    client.Dispose();
                }
            }

            DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < deadline && tries.Any(t => !t.Task.IsCompleted))
                Thread.Sleep(20);

            foreach ((string ip, TcpClient client, Task task) in tries)
            {
                try
                {
                    if (task.Status == TaskStatus.RanToCompletion && client.Connected)
                        found.Add(ip);
                }
                catch
                {
                    // 连不上就是没开 5555，继续扫下一个
                }
                client.Dispose();
            }
        }
        return found;
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
    /// allowWireless=true 时先主动发现无线调试端点（每次 mDNS，深度再扫 /24 的 5555），
    /// 再读取 adb devices —— 否则 mDNS 广播里的手机永远只停留在"广播"层，不会出现在列表里。
    /// </summary>
    public List<DeviceRow> Inventory(bool deep, bool allowWireless)
    {
        PickerConfig cfg = _cfg.Snapshot();
        bool preferUsb = cfg.Settings.PreferUsb;

        if (allowWireless) EnsureWireless(Tc(), cfg, deep);

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
