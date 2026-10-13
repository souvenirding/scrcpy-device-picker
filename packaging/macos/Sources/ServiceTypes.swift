// ServiceTypes.swift - 服务层强类型契约（design 2.2.2 A / 2.3.2，spec 6.2 / 8.1）
//
// 纯值类型定义，不依赖任何业务模块（design 1.1.3 C：依赖"无"）。
// 错误码与原 HTTP 版错误字符串语义一一对应（spec 6.2 约束 1），
// 供 ViewModel 精确分支提示文案，替代原 HTTP 版的无类型字典载荷（spec 6.2 约束 1）。
import Foundation

// MARK: - 通道与模式

/// 通道展示标签：rawValue 即展示文案，逐字对齐 spec 5.1 规则 3 / 8.1。
/// 原版 Conn 元素是机器码 "USB"/"TLS"/"TCP"，中文标签由前端 CONN_LABEL 翻译；
/// 强类型化后由枚举 rawValue 直接承载，消除前端翻译层（design 1.2.3 迁移红线）。
enum ConnKind: String, Codable, Equatable {
    case usb     = "USB"
    case tls     = "无线调试"
    case tcp5555 = "TCP 5555"
}

/// 投屏请求模式（对齐原 /api/cast 的 mode 字段）。
enum CastMode: String {
    case auto      // 双击 / 右键"投屏（自动选通道）" / "投屏（不同步剪贴板）" / "强制重新投屏"
    case usb       // 右键"用 USB 投屏"
    case tls       // 预留（原版路由已支持，右键菜单当前未暴露）
    case tcp       // 预留（同上）
}

// MARK: - 错误与结果

/// 稳定错误码（对齐原 HTTP 版错误字符串，供 ViewModel 精确分支）。
enum ServiceError: Error, Equatable {
    case scrcpyExited(detail: String, target: String)   // 原 "scrcpy_exited"
    case noTransport                                    // 原 "device has no reachable transport" / "no live target for device"
    case inputInjectBlocked(code: Int, target: String)  // 原 "input_inject_blocked"
    case badKeyEventCode                                // 原 "bad keyevent code"
    case deviceNotFound                                 // key 查找失败兜底
}

/// 投屏结果（对齐原 /api/cast 的四种响应分支，spec 6.2 表 4）。
enum CastResult: Equatable {
    case started(pid: Int32, target: String, logPath: String)   // 进程已拉起且 1.5s 存活
    case already(pid: Int32, target: String)                    // 复用现有/认领进程
    case exited(detail: String, target: String, pid: Int32)     // 启动后立即退出（detail=日志前 8 行摘要）
    case noTransport                                            // 无可用通道
}

/// 按键结果（对齐原 /api/nav 响应分支，spec 6.2 表 5）。
enum NavResult: Equatable {
    case sent(code: Int, target: String)
    case blocked(code: Int, target: String)   // input_inject_blocked；小米/MIUI/HyperOS 指引由 ViewModel 呈现
    case failure(ServiceError)
}

// MARK: - 状态与快照

/// 投屏状态查询结果（对齐原 /api/caststate，spec 6.2 表 3）。
struct CastProgress: Equatable {
    let key: String
    let pid: Int32
    let running: Bool          // 进程存活（pgrep -x scrcpy 校验）
    let ready: Bool            // 日志出现就绪特征
    let elapsed: TimeInterval  // 已等待秒数；-1 = 无起始时间（孤儿防御分支，对齐原版语义）
}

/// 应用状态（对齐原 /api/status，spec 6.2 表 2；无 port 字段——HTTP 层随重构移除）。
struct AppStatus: Equatable {
    let adbPath: String
    let adbVersion: String
    let scrcpyPath: String
    let scrcpyVersion: String
    let adbMissing: Bool
    let lastRefresh: String    // ISO8601，空串 = 尚未刷新
    let wirelessEnabled: Bool  // 恒 false（allowWireless=false，spec 1.4 边界 3）
}

/// 设备行 UI 视图模型（spec 8.1 逐字段；design 2.3.2）。
/// 属性语义与原 HTTP 版行组装输出的 PascalCase 键一一对应（Key→key、Name→name……）；
/// 值类型，快照拷贝即深拷贝；不持久化（纯内存视图模型）。
struct DeviceRowVM: Identifiable, Equatable {
    let key: String          // Key：设备稳定标识（真实序列号优先），非空；操作寻址唯一键
    let name: String         // Name：显示名，优先级 Alias > DevName > Model > Key，不允许为空
    let model: String        // Model：型号（getprop，取不到为空串）
    let device: String       // Device：产品代号
    let android: String      // Android：系统版本
    let conn: [ConnKind]     // Conn：通道标签数组，多元素按 USB→无线调试→TCP 5555 固定顺序
    let addr: String         // Addr：地址，优先级 TLS > TCP 5555 > Wi-Fi IP；可为空
    let battery: String      // Battery：电量百分比数字字符串（无 % 号，展示时拼接）
    let charging: String     // Charging：充电状态 ∈ {充电中, 放电, 已充满, 空}
    let online: Bool         // Online：在线（与 offline 互斥）
    let offline: Bool        // Offline：离线
    let preferred: String    // Preferred：首选投屏目标（按 preferUsb 计算）；离线行为空串
    let usb: Bool            // Usb：是否有 USB 通道
    let usbSerial: String    // UsbSerial：adb 认可的 USB 字面传输名（Key 不能直接当 -s 参数）
    let tls: String          // Tls：无线调试传输名；无则空串
    let tcp5555: String      // Tcp5555：TCP 5555 传输名；无则空串

    /// Identifiable：id = key（设备稳定标识）。
    var id: String { key }
}

/// 设备快照（对齐原 /api/devices 响应，spec 6.2 表 1）。
struct DeviceSnapshot: Equatable {
    let rows: [DeviceRowVM]
    let lastRefresh: String
    let error: String          // 刷新异常文本，非空时界面横幅呈现（如 adb 二进制不可执行）
}

/// 刷新完成通知载荷（新增：替代前端 10s 轮询拉取，design 2.1.3 线程模型）。
struct RefreshPayload {
    let snapshot: DeviceSnapshot
    let status: AppStatus
}