// RowBuilder.swift - 设备行组装（强类型化改造自原 HTTP 版行组装，design 1.2.3 / 2.2.2 D）
//
// 组装规则与原 HTTP 版 build(online:) 逐行对照一致（design 1.2.3 五条规则红线）：
//   1. Name 优先级 Alias > DevName > Model > Key（在线/离线两分支）
//   2. Addr 优先级 tls > tcp5555 > wifiIp；离线行用 TlsLast 或 WifiIp+":5555"
//   3. Conn 在线按 USB→TLS→TCP 固定顺序；离线按 KnownUsb/TlsLast/WifiIp 推断
//   4. 离线行 Battery/Charging/Preferred 置空
//   5. 排序：在线优先，Name 升序
// 副作用保留：build 过程回写 TlsLast/KnownUsb 到 ConfigStore（spec 6.4 保留清单）——
// 离线行能显示历史地址全靠这一步。
// 仅数据载体变化：字典字面量 → DeviceRowVM 属性；Conn 元素 "TLS"/"TCP" → ConnKind 枚举
// （展示标签由 rawValue 承载，消除前端翻译层）；排序比较器改属性访问。
import Foundation

enum RowBuilder {
    static func build(online: [DeviceRow]) -> [DeviceRowVM] {
        let cfg = ConfigStore.shared.snapshot()
        var rows: [DeviceRowVM] = []
        var seen = Set<String>()

        for o in online {
            let alias = cfg.devices[o.key]?.Alias ?? ""
            let name = !alias.isEmpty ? alias
                : (!o.devName.isEmpty ? o.devName
                : (!o.model.isEmpty ? o.model : o.key))

            var conn: [ConnKind] = []
            if o.usb { conn.append(.usb) }
            if !o.tls.isEmpty { conn.append(.tls) }
            if !o.tcp5555.isEmpty { conn.append(.tcp5555) }

            let addr = !o.tls.isEmpty ? o.tls
                : (!o.tcp5555.isEmpty ? o.tcp5555 : o.wifiIp)

            rows.append(DeviceRowVM(
                key: o.key, name: name, model: o.model, device: o.device,
                android: o.android, conn: conn, addr: addr,
                battery: o.battery, charging: o.charging,
                online: true, offline: false,
                preferred: o.preferred, usb: o.usb, usbSerial: o.usbSerial,
                tls: o.tls, tcp5555: o.tcp5555
            ))
            seen.insert(o.key)
        }

        // 之前见过的设备继续列出，但标记为离线（UI 置灰）
        for (k, c) in cfg.devices where !seen.contains(k) {
            let alias = c.Alias ?? ""
            let devName = c.DevName ?? ""
            let model = c.Model ?? ""
            let name = !alias.isEmpty ? alias
                : (!devName.isEmpty ? devName
                : (!model.isEmpty ? model : k))
            var conn: [ConnKind] = []
            if c.KnownUsb == true { conn.append(.usb) }
            let tlsLast = c.TlsLast ?? ""
            let wifiIp = c.WifiIp ?? ""
            if !tlsLast.isEmpty { conn.append(.tls) }
            if !wifiIp.isEmpty { conn.append(.tcp5555) }
            let addr = !tlsLast.isEmpty ? tlsLast
                : (!wifiIp.isEmpty ? wifiIp + ":5555" : "")
            rows.append(DeviceRowVM(
                key: k, name: name, model: model, device: c.Device ?? "",
                android: c.Android ?? "", conn: conn, addr: addr,
                battery: "", charging: "",
                online: false, offline: true,
                preferred: "", usb: false, usbSerial: "",
                tls: "", tcp5555: ""
            ))
        }

        // 记住上次见到的端点，离线行才能继续显示地址（副作用：回写 ConfigStore）。
        // 锁内合并写（M1/M5）：mutate 只碰 TlsLast/KnownUsb 且仅在值实际变化时改，
        // 绝不整体覆盖条目——并发 setAlias 的备注名不会被本轮回写回滚；
        // 无变化时 updateDevice 不写盘。
        for o in online {
            ConfigStore.shared.updateDevice(o.key) { c in
                if !o.tls.isEmpty && c.TlsLast != o.tls { c.TlsLast = o.tls }
                if o.usb && !(c.KnownUsb ?? false) { c.KnownUsb = true }
            }
        }

        // 在线优先，其次按名称
        rows.sort { a, b in
            if a.offline != b.offline { return !a.offline }
            return a.name < b.name
        }
        return rows
    }
}