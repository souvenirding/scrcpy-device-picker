// ConfigStore.swift - devices.json（备注名 + 设备详情缓存）
//
// 字段沿用 PowerShell 版的 PascalCase，保证与 Windows 端共用同一份缓存格式。
// 存放位置从 app 包内（旧行为，包不该被写）改为
// ~/Library/Application Support/ScrcpyPicker/devices.json；
// 首次运行时会把包内的旧文件迁移过来，避免已有备注名丢失。
import Foundation

struct DeviceCache: Codable, Equatable {
    var ts: String?
    var Model: String?
    var Device: String?
    var Android: String?
    var Brand: String?
    var DevName: String?
    var WifiIp: String?
    var Battery: String?
    var Charging: String?
    var Alias: String?
    var TlsLast: String?
    var KnownUsb: Bool?

    /// 非 Codable 的容错：adb 偶尔返回非字符串，或者字段缺失，都要能读回来。
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        ts = try? c.decode(String.self, forKey: .ts)
        Model = try? c.decode(String.self, forKey: .Model)
        Device = try? c.decode(String.self, forKey: .Device)
        Android = try? c.decode(String.self, forKey: .Android)
        Brand = try? c.decode(String.self, forKey: .Brand)
        DevName = try? c.decode(String.self, forKey: .DevName)
        WifiIp = try? c.decode(String.self, forKey: .WifiIp)
        Battery = try? c.decode(String.self, forKey: .Battery)
        Charging = try? c.decode(String.self, forKey: .Charging)
        Alias = try? c.decode(String.self, forKey: .Alias)
        TlsLast = try? c.decode(String.self, forKey: .TlsLast)
        KnownUsb = try? c.decode(Bool.self, forKey: .KnownUsb)
    }
    enum K: String, CodingKey {
        case ts, Model, Device, Android, Brand, DevName, WifiIp, Battery, Charging, Alias, TlsLast, KnownUsb
    }
}

struct PickerSettings: Codable {
    var preferUsb: Bool = true
    var scanSubnet: Bool = true
}

struct PickerConfig: Codable {
    var devices: [String: DeviceCache] = [:]
    var settings: PickerSettings = PickerSettings()
}

final class ConfigStore {
    static let shared = ConfigStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var config: PickerConfig

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("ScrcpyPicker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("devices.json")

        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(PickerConfig.self, from: data) {
            config = cfg
        } else {
            config = PickerConfig()
            // 迁移：旧版本把 devices.json 写在 app 包内 scripts/shared/。
            if let bundled = Bundle.main.resourcePath {
                let legacy = bundled + "/scripts/shared/devices.json"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: legacy)),
                   let cfg = try? JSONDecoder().decode(PickerConfig.self, from: data) {
                    config = cfg
                    save()
                }
            }
        }
    }

    /// 快照式读取，避免调用方拿到内部可变引用后跨线程改。
    func snapshot() -> PickerConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    func device(_ key: String) -> DeviceCache? {
        lock.lock(); defer { lock.unlock() }
        return config.devices[key]
    }

    func setDevice(_ key: String, _ value: DeviceCache) {
        lock.lock()
        config.devices[key] = value
        lock.unlock()
        save()
    }

    /// 锁内合并写（读-改-写原子化）：读当前条目（无则新建空条目）→ 应用 mutate →
    /// 写回并落盘。用于刷新线程的局部字段回写——与主线程 setAlias 并发时，
    /// mutate 只碰自己负责的字段、其余字段取锁内最新值，用户刚保存的备注名
    /// 不会被探测前的旧快照整体覆盖回滚（Phase F M1）。
    /// mutate 未产生实际变化时不写盘（避免无谓 IO，M5）。
    func updateDevice(_ key: String, _ mutate: (inout DeviceCache) -> Void) {
        lock.lock()
        var c = config.devices[key] ?? DeviceCache()
        let before = c
        mutate(&c)
        if c != before {
            config.devices[key] = c
            saveLocked()
        }
        lock.unlock()
    }

    func removeDevice(_ key: String) {
        lock.lock()
        config.devices.removeValue(forKey: key)
        lock.unlock()
        save()
    }

    func settings() -> PickerSettings {
        lock.lock(); defer { lock.unlock() }
        return config.settings
    }

    /// 落盘：编码在锁内完成（消除"解锁后编码期间内存又被改、写盘顺序与
    /// 数据新旧脱节"的不一致窗口，M1④）；原子写盘几 KB 量级，锁内开销可忽略。
    /// 调用方不持锁（updateDevice 走 saveLocked 避免重入死锁）。
    func save() {
        lock.lock()
        saveLocked()
        lock.unlock()
    }

    /// 锁内编码 + 原子写盘（调用方必须已持锁；NSLock 不可重入）。
    private func saveLocked() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    var path: String { return fileURL.path }
}
