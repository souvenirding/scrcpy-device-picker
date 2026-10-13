// Discovery.swift - 设备发现核心（移植自 shared/Discover.ps1）
//
// 分类规则是上一轮修 bug 的关键，必须逐条照搬：
//   * 以 "_adb-tls-connect._tcp" 结尾  -> 无线调试(TLS)
//   * "ip:5555"                        -> 传统 adbd(TCP)
//   * "ip:<其他端口>"                   -> TLS
//   * 其余                              -> USB
// 绝不能用"串号里没有冒号就是 USB"来判断：mDNS 服务名里根本没有冒号。
import Foundation

enum TransportKind: String {
    case usb
    case tls
    case tcp5555
}

struct Transport {
    let serial: String
    let model: String
    let product: String
    let kind: TransportKind
}

struct DeviceDetail {
    var serialNo = ""
    var model = ""
    var device = ""
    var android = ""
    var brand = ""
    var devName = ""
    var battery = ""
    var charging = ""
    var wifiIp = ""
}

struct DeviceRow {
    var key: String
    var alias = ""
    var model = ""
    var device = ""
    var android = ""
    var brand = ""
    var devName = ""
    var battery = ""
    var charging = ""
    var wifiIp = ""
    var usb = false
    var usbSerial = ""
    var tls = ""
    var tcp5555 = ""
    var online = true
    var preferred = ""
    var connections = ""

    init(key: String) { self.key = key }
}

final class Discovery {
    let tools: Toolchain
    private let lock = NSLock()
    /// adb 传输名 -> 真实串号。无线调试下两者不同（传输名是 mDNS 服务名），
    /// 而备注名/详情缓存是按真实串号存的；不记住这层映射，每次刷新都会用一个
    /// "查不到的 Key" 去读缓存，于是备注名被空值覆盖、getprop 每 10 秒重跑一次。
    private var knownSerial: [String: String] = [:]

    init(tools: Toolchain) {
        self.tools = tools
    }

    private func serial(for transport: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return knownSerial[transport] ?? transport
    }

    private func remember(transport: String, serial: String) {
        lock.lock(); defer { lock.unlock() }
        knownSerial[transport] = serial
    }

    // MARK: - adb devices -l 分类

    func usbTransports() -> [Transport] {
        var res: [Transport] = []
        for line in tools.adb(["devices", "-l"]) {
            guard let g = reGroups(#"^(\S+)\s+device\s"#, line), g.count > 1 else { continue }
            let serial = g[1]
            var model = ""
            var product = ""
            if let m = reGroups(#"model:(\S+)"#, line), m.count > 1 { model = m[1] }
            if let p = reGroups(#"product:(\S+)"#, line), p.count > 1 { product = p[1] }

            var kind = TransportKind.usb
            if reTest(#"_adb-tls-connect\._tcp$"#, serial) {
                kind = .tls
            } else if let ip = reGroups(#"^(\d+\.\d+\.\d+\.\d+):(\d+)$"#, serial), ip.count > 2 {
                kind = (ip[2] == "5555") ? .tcp5555 : .tls
            }
            res.append(Transport(serial: serial, model: model, product: product, kind: kind))
        }
        return res
    }

    /// adb devices -> [serial: state]，用于投屏前实时校验传输名。
    func liveTransports() -> [String: String] {
        var map: [String: String] = [:]
        for line in tools.adb(["devices"]) {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if cols.count < 2 { continue }
            map[cols[0]] = cols[1]
        }
        return map
    }

    /// 在所有候选里挑一个 adb 当前真的列为 device 的；一个都没有时退回首选，
    /// 好让 scrcpy/adb 自己报出真正的错误，而不是静默失败。
    func resolveTarget(key: String, preferred: String = "", usbSerial: String = "",
                       tls: String = "", tcp5555: String = "") -> String? {
        var cands: [String] = []
        for c in [preferred, usbSerial, tls, tcp5555, key] where !c.isEmpty && !cands.contains(c) {
            cands.append(c)
        }
        if cands.isEmpty { return nil }
        let live = liveTransports()
        for c in cands {
            if live[c] == "device" { return c }
        }
        return cands[0]
    }

    // MARK: - 设备详情（一次 shell 往返，用哨兵分段）

    func deviceDetail(serial: String) -> DeviceDetail? {
        let cmd = "echo MK_S1; getprop ro.serialno; echo MK_S2; getprop ro.product.model; echo MK_S3; "
            + "getprop ro.product.device; echo MK_S4; getprop ro.build.version.release; echo MK_S5; "
            + "getprop ro.product.brand; echo MK_S6; settings get global device_name; echo MK_S7; "
            + "ip -4 addr show wlan0; echo MK_S8; dumpsys battery"
        let lines = tools.adb(["-s", serial, "shell", cmd])

        var sections: [String: [String]] = [:]
        var current = ""
        for raw in lines {
            let ln = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
            if let g = reGroups(#"^MK_S(\d)$"#, ln), g.count > 1 {
                current = g[1]
                sections[current] = []
                continue
            }
            if !current.isEmpty { sections[current, default: []].append(ln.trimmed()) }
        }
        guard sections["2"] != nil else { return nil }   // 拿不到型号 -> 视为无效

        func sec(_ n: String) -> String {
            guard let v = sections[n]?.first, !v.isEmpty else { return "" }
            return v == "null" ? "" : v
        }

        var d = DeviceDetail()
        d.serialNo = sec("1")
        d.model = sec("2")
        d.device = sec("3")
        d.android = sec("4")
        d.brand = sec("5")
        d.devName = sec("6")

        for v in (sections["7"] ?? []) + (sections["8"] ?? []) {
            if let g = reGroups(#"^\s*level:\s*(\d+)"#, v), g.count > 1 {
                d.battery = g[1]
            } else if let g = reGroups(#"^\s*status:\s*(\d+)"#, v), g.count > 1 {
                switch g[1] {
                case "2": d.charging = "充电中"
                case "3": d.charging = "放电"
                case "4": d.charging = "已充满"
                default: d.charging = ""
                }
            } else if let g = reGroups(#"inet\s+([0-9]+(?:\.[0-9]+){3})"#, v), g.count > 1 {
                if d.wifiIp.isEmpty { d.wifiIp = g[1] }
            }
        }
        return d
    }

    // MARK: - 合并清单

    /// allowWireless 为 false 时不做 mDNS 发现和子网扫描 —— 与 macOS 版 PowerShell
    /// 的 -SkipWireless / -SkipScan 默认行为一致（共享网络下不自动连陌生设备）。
    func inventory(deep: Bool, allowWireless: Bool = false) -> [DeviceRow] {
        var cfg = ConfigStore.shared.snapshot()
        let preferUsb = cfg.settings.preferUsb

        var rows: [String: DeviceRow] = [:]

        for u in usbTransports() {
            // 已经认识这个传输名时，直接用真实串号做 Key，缓存/备注名才对得上。
            let transport = u.serial
            let key = serial(for: transport)
            var r = rows[key] ?? DeviceRow(key: key)
            r.model = u.model
            switch u.kind {
            case .usb:
                r.usb = true
                // UsbSerial 恒为 adb 认的字面传输名；Key 稍后可能被真实串号替换，
                // 所以 Key 永远不能直接当 -s 的参数用。
                r.usbSerial = transport
            case .tls:     r.tls = transport
            case .tcp5555: r.tcp5555 = transport
            }
            r.online = true
            rows[key] = r
        }

        // 详情填充（带缓存；deep 或缓存过期才重新取）
        for key in Array(rows.keys) {
            guard var r = rows[key] else { continue }
            let cache = cfg.devices[key]
            var stale = true
            if let c = cache, let ts = c.ts, !deep, let m = c.Model, !m.isEmpty {
                if let date = isoDate(ts), Date().timeIntervalSince(date) <= 60 { stale = false }
            }
            if stale {
                let probe = (r.usb && !r.usbSerial.isEmpty) ? r.usbSerial
                    : (!r.tls.isEmpty ? r.tls : (!r.tcp5555.isEmpty ? r.tcp5555 : key))
                if let det = deviceDetail(serial: probe) {
                    remember(transport: probe, serial: det.serialNo.isEmpty ? probe : det.serialNo)
                    // 详情可能暴露出：我们临时用的 key 并不是真实串号
                    let finalKey = det.serialNo.isEmpty ? key : det.serialNo
                    // 换 Key 迁移：备注名可能挂在旧 Key（传输名）上，也可能已经挂在
                    // 真实串号上；finalKey 已有条目时其 Alias 优先，否则继承旧 Key 的。
                    var c = cfg.devices[finalKey] ?? DeviceCache()
                    if finalKey != key, (c.Alias ?? "").isEmpty, let la = cache?.Alias, !la.isEmpty {
                        c.Alias = la
                    }
                    c.ts = isoNow()
                    c.Model = det.model
                    c.Device = det.device
                    c.Android = det.android
                    c.Brand = det.brand
                    c.DevName = det.devName
                    c.WifiIp = det.wifiIp
                    c.Battery = det.battery
                    c.Charging = det.charging
                    if finalKey != key {
                        rows.removeValue(forKey: key)
                        r.key = finalKey
                        rows[finalKey] = r
                        cfg.devices.removeValue(forKey: key)
                        ConfigStore.shared.removeDevice(key)
                    }
                    cfg.devices[finalKey] = c
                    // 锁内合并写（M1）：详情字段来自本轮探测整体更新；Alias 仅在
                    // 锁内条目为空时补写（换 Key 迁移），锁内已有值——并发 setAlias
                    // 刚保存的备注名——原样保留，不再被探测前的旧快照回滚。
                    ConfigStore.shared.updateDevice(finalKey) { latest in
                        if (latest.Alias ?? "").isEmpty { latest.Alias = c.Alias }
                        latest.ts = c.ts
                        latest.Model = c.Model
                        latest.Device = c.Device
                        latest.Android = c.Android
                        latest.Brand = c.Brand
                        latest.DevName = c.DevName
                        latest.WifiIp = c.WifiIp
                        latest.Battery = c.Battery
                        latest.Charging = c.Charging
                    }
                }
            }

            guard var rr = rows[r.key] else { continue }
            if let c = cfg.devices[r.key] {
                rr.model = c.Model ?? ""
                rr.device = c.Device ?? ""
                rr.android = c.Android ?? ""
                rr.brand = c.Brand ?? ""
                rr.devName = c.DevName ?? ""
                rr.wifiIp = c.WifiIp ?? ""
                rr.alias = c.Alias ?? ""
                rr.battery = c.Battery ?? ""
                rr.charging = c.Charging ?? ""
            }

            let usbHandle = (rr.usb && !rr.usbSerial.isEmpty) ? rr.usbSerial : (rr.usb ? rr.key : "")
            if preferUsb {
                rr.preferred = !usbHandle.isEmpty ? usbHandle : (!rr.tls.isEmpty ? rr.tls : rr.tcp5555)
            } else {
                rr.preferred = !rr.tls.isEmpty ? rr.tls : (!rr.tcp5555.isEmpty ? rr.tcp5555 : usbHandle)
            }
            var conns: [String] = []
            if rr.usb { conns.append("USB") }
            if !rr.tls.isEmpty { conns.append("无线调试") }
            if !rr.tcp5555.isEmpty { conns.append("TCP 5555") }
            rr.connections = conns.joined(separator: " + ")
            rows[rr.key] = rr
        }

        return Array(rows.values)
    }

    func disconnect(_ endpoint: String) {
        guard endpoint.contains(":") else { return }
        _ = tools.adb(["disconnect", endpoint])
    }
}

// MARK: - 时间小工具

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

func isoDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    let g = ISO8601DateFormatter()
    g.formatOptions = [.withInternetDateTime]
    return g.date(from: s)
}

extension String {
    func trimmed() -> String {
        return trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
