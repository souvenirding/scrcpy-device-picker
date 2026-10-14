// TransferTypes.swift - 文件传输领域值类型与常量契约（design 2.3.2 / 2.5，spec 第 2 章）
//
// 纯值类型定义，不依赖任何业务模块（对齐 ServiceTypes.swift:3「依赖无」定位）。
// 供 TransferManager（服务层）/ TransferViewModel（@MainActor）/ 传输视图共同引用；
// 本文件只承载类型与常量，不含任何业务逻辑（受理判定与进程执行分别在
// TransferManager 与执行器中，design 2.9.1）。
//
// 中文文案集中声明（design 2.5）：用户可见文案一律取 TransferCardText 与
// TransferFailureReason.displayText，视图与 ViewModel 不内联字符串字面量。
import Foundation

// MARK: - 方向与任务状态

/// 传输方向：push = Mac → 设备；pull = 设备 → Mac（spec 第 2 章「推送/拉取」）。
enum TransferDirection {
    case push
    case pull
}

/// 传输任务状态机四态（design 2.1.3.1：进行中 → 成功 / 部分失败 / 失败）。
enum TransferTaskState {
    case running
    case succeeded
    case partialFailure
    case failed
}

// MARK: - 失败原因

/// adb 输出映射出的失败原因（design 2.4.7 六行规则表 + FT-NOTIF-4 中文短语）。
/// displayText 集中承载用户可见文案（对齐 ServiceError.displayReason 先例）。
enum TransferFailureReason {
    case deviceDisconnected                 // 设备连接中断
    case deviceStorageFull                  // 设备存储空间不足
    case macDiskFull                        // Mac 磁盘空间不足
    case deviceUnreachable                  // 设备当前不可达（严格现算无 live 传输名）
    case adbUnavailable                     // adb 不可用（adbResolved == false）
    case directoryMissing(name: String)     // 设备上没有该目录
    case directoryEmpty                     // 目录为空，没有拉取到文件
    case unknown(summary: String)           // 无法归类：adb 错误输出首行摘要

    var displayText: String {
        switch self {
        case .deviceDisconnected:
            return TransferCardText.deviceDisconnected
        case .deviceStorageFull:
            return TransferCardText.deviceStorageFull
        case .macDiskFull:
            return TransferCardText.macDiskFull
        case .deviceUnreachable:
            return TransferCardText.deviceUnreachable
        case .adbUnavailable:
            return TransferCardText.adbUnavailable
        case .directoryMissing(let name):
            guard !name.isEmpty else { return TransferCardText.directoryMissingNoName }
            return String(format: TransferCardText.directoryMissingFormat, name)
        case .directoryEmpty:
            return TransferCardText.directoryEmpty
        case .unknown(let summary):
            return summary
        }
    }
}

// MARK: - 受理与终态结果

/// 受理结果七分支（design 2.2.2 接口组 1 异常映射表）。
/// 非 .started 分支一律表示「未登记活动表、未拉起任何 adb 进程」。
enum TransferStartResult {
    case started(taskID: TransferTaskID)
    case rejectedOffline          // 行不存在或已离线（FT-DRAG-4 服务端防线）
    case rejectedDeviceBusy       // 该设备已有进行中任务（FT-COMMON-5 每设备互斥）
    case rejectedGlobalLimit      // 全局并发达上限（FT-COMMON-5 全局 3 上限）
    case failedAdbMissing         // adbResolved == false（FT-ERR-6）
    case failedUnreachable        // 严格现算无 live 传输名（FT-ERR-7）
    case failed(reason: TransferFailureReason)
}

/// 任务终态（design 2.1.3.1 状态机终态节点 + 用户主动取消）。
/// .cancelled 独立于 .failed：取消是用户预期内的终止，非错误，
/// 故不承载 TransferFailureReason，卡片以 warn 相位呈现。
enum TransferFinalResult {
    case succeeded(fileCount: Int)
    case partialFailure(successCount: Int, failureCount: Int, firstFailure: TransferFailureReason)
    case failed(reason: TransferFailureReason)
    case cancelled
}

// MARK: - 标识与快捷目录

/// 任务唯一标识（纯内存，不持久化；UUID 字符串包装）。
struct TransferTaskID: Identifiable, Hashable {
    let rawValue: String

    init() { self.rawValue = UUID().uuidString }
    init(_ rawValue: String) { self.rawValue = rawValue }

    var id: String { rawValue }
}

/// 卡片唯一标识。独立于任务 ID —— 拒绝类提示卡片无任务 ID，需独立生成
/// （design 2.3.2「拒绝类提示卡片直接以终态入列」）。
struct TransferCardID: Identifiable, Hashable {
    let rawValue: String

    init() { self.rawValue = UUID().uuidString }

    var id: String { rawValue }
}

/// 设备端常用拉取目录（spec FT-PULL-1 恰三项，design 2.5 quickPullDirectories）。
/// displayName 同时用于菜单文案与 Mac 端落地目录名。
struct QuickPullDirectory: Hashable {
    let displayName: String
    let devicePath: String

    static let download = QuickPullDirectory(displayName: "Download", devicePath: "/sdcard/Download")
    static let dcim     = QuickPullDirectory(displayName: "DCIM", devicePath: "/sdcard/DCIM")
    static let pictures = QuickPullDirectory(displayName: "Pictures", devicePath: "/sdcard/Pictures")
}

// MARK: - 进度与卡片

/// 单个传输任务的进度快照；percent 为 nil 即降级态（视图渲染转圈，FT-PROG-4）。
struct TransferProgressSnapshot {
    let fileIndex: Int      // 1-based 当前文件序号
    let totalFiles: Int
    let fileName: String
    let percent: Int?       // 0...100；nil = 不定进度
}

/// 右下角传输卡片状态（design 2.3.2）。
/// phase 复用既有 DeviceListViewModel.ToastPhase 四态（running/ok/warn/err，
/// 部分失败用 warn）—— 仅引用、不修改 DeviceListViewModel（design 2.9.3 零改动）。
struct TransferCardState: Identifiable {
    let id: TransferCardID
    /// 关联任务；nil 表示拒绝/提示类即时卡片（无任务、无进度）。
    let taskID: TransferTaskID?
    let phase: DeviceListViewModel.ToastPhase
    let title: String
    let subtitle: String
    let progress: TransferProgressSnapshot?
}

/// 服务层活动表记录（design 2.3.2；锁内创建与注销）。
/// reservedDestinationName 仅拉取任务使用：并发拉取同名目录的防御（design 2.4.1）。
struct ActiveTaskRecord {
    let taskID: TransferTaskID
    let deviceKey: String
    let direction: TransferDirection
    let startedAt: Date
    var reservedDestinationName: String?
    /// 用户已请求取消（cancel(taskID:) 置位；执行器据此发 .cancelled 终态并清理残留）
    var isCancelled = false
}

// MARK: - 服务层回调载荷（design 2.2.2 接口组 1）

/// 进度更新（服务层保证经主队列回调）。
struct TransferProgressUpdate {
    let taskID: TransferTaskID
    let fileIndex: Int
    let totalFiles: Int
    let fileName: String
    let percent: Int?
}

/// 任务终态（服务层保证经主队列回调）。
struct TransferFinalUpdate {
    let taskID: TransferTaskID
    let deviceKey: String
    let direction: TransferDirection
    let outcome: TransferFinalResult
}

// MARK: - 常量（design 2.5：杜绝魔法字符串与魔法数字）

enum TransferConstants {

    /// 推送目标目录（FT-COMMON-2/3，D1 固定不可配置）
    static let devicePushDirectory = "/sdcard/Download"
    /// push 目标尾斜杠片段：与上一项拼接为 `/sdcard/Download/`，
    /// 使 adb 按「目标为已存在目录 → 写入其下」语义落地（design 2.4.1）
    static let devicePushTargetSuffix = "/"

    /// 拼接后的推送目标路径
    static var devicePushTarget: String { devicePushDirectory + devicePushTargetSuffix }

    /// 快捷拉取目录三项（子菜单与拉取命令的唯一数据源；增删目录只改此处，D6/D11）
    static let quickPullDirectories: [QuickPullDirectory] = [.download, .dcim, .pictures]

    /// 拉取落地父目录（Mac「下载」文件夹，D2）。用古老的 FileManager API，
    /// 不用 URL.downloadsDirectory 便捷属性（design 2.7 核查表）
    static var downloadsDirectoryURL: URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        guard let url = try? FileManager.default.url(for: .downloadsDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: false) else { return fallback }
        return url
    }

    /// 落地名递增分隔符（如 "DCIM 2"，对齐 Finder「副本」命名风格，D3）
    static let destinationNameSeparator = " "
    /// 落地名探测次数上限（防御性：异常文件系统下不至于无限循环）
    static let maxDestinationNameAttempts = 1000

    /// 全局同时进行的传输任务上限（FT-COMMON-5，D7）
    static let maxConcurrentTransfers = 3
    /// 卡片区同时渲染上限，超出走汇总行（FT-PROG-3）
    static let maxVisibleCards = 3

    /// 成功卡片自动消失时长（FT-NOTIF-1）
    static let successCardDuration: TimeInterval = 3.0
    /// 失败 / 部分失败卡片自动消失时长（FT-NOTIF-2/3）
    static let failureCardDuration: TimeInterval = 8.0
    /// warn 提示 / 拒绝 / 空目录卡片自动消失时长（对齐 ToastDuration.warnMutex 先例）
    static let noticeCardDuration: TimeInterval = 3.0

    /// adb 进度行正则：形如 `[ 42%] /sdcard/Download/x.jpg`（百分号前可有对齐空格）。
    /// 保留原因：adb 在 stderr 为 TTY 时会输出该格式（如用户在终端手工执行），
    /// 解析逻辑留作兜底通道；实测 adb 1.0.41 在 Pipe 接管下不输出此行，
    /// 真实进度改由 TransferSizeProbe 字节实测换算（D-PROGRESS）。
    static let progressLinePattern = #"^\[\s*(\d+)%\]"#

    // MARK: 字节实测进度（D-PROGRESS）
    //
    // 实测结论：adb 1.0.41（Version 37.0.1）在 stderr 非 TTY 时不输出 `[ 42%]` 进度行，
    // 仅于传输结束输出一行摘要。故进度改为「已传输字节 / 总字节」实测换算：
    //   * 推送：总字节 = Mac 本地源（文件/文件夹递归），已传输 = 设备端 du -sk 实测
    //   * 拉取：总字节 = 设备端 du -sk 实测，已传输 = Mac 落地目录递归实测

    /// 推送轮询间隔（秒）。推送实测可达 GB/s 级（150MB≈0.34s、2GB≈1.2s），
    /// 间隔必须够密才采得到中间进度；单文件测量走 O(1) 的 stat，代价极低。
    static let pushProgressPollInterval: TimeInterval = 0.25
    /// 拉取轮询间隔（秒）。测量为 Mac 侧目录递归，代价随文件数增长，取 1s。
    static let pullProgressPollInterval: TimeInterval = 1.0
    /// 首次轮询延迟：留出让 adb 真正开始写入的时间，避免首拍恒为 0%
    static let progressPollInitialDelay: TimeInterval = 0.3
    /// `du -sk` 输出单位为 KiB
    static let duKiloBytesPerBlock: Int64 = 1024
    /// du 命令参数（`-sk`：递归汇总、以 KiB 计）。实测设备端不支持 `-sb`
    static let duArguments = ["du", "-sk"]
    /// stat 命令参数（`-c %s`：单文件大小，不递归，O(1)）。推送高频轮询用
    static let statSizeArguments = ["stat", "-c", "%s"]
    /// 进度分母下限保护：总字节为 0 时不做轮询，直接降级不定进度
    static let minimumProgressTotalBytes: Int64 = 1

    /// 失败映射匹配特征串（design 2.4.7；大小写不敏感匹配）
    enum failurePatterns {
        /// 断连特征组（双向 → deviceDisconnected）
        /// 逐条对齐 adb 真实报文：device offline / device '序列号' not found /
        /// device unauthorized / connection reset / protocol fault / closed
        static let disconnected = ["device offline", "device not found", "not found",
                                   "device unauthorized", "connection reset",
                                   "protocol fault", "closed"]
        /// 空间不足（按方向分流：push → 设备、pull → Mac）
        static let noSpace = ["No space left on device"]
        /// 拉取预检期目录不存在
        static let dirMissing = ["No such file or directory", "does not exist"]
        /// 预检输出为空即目录为空（FT-PULL-4）
        static let emptyDirectoryProbe = "ls -A"
    }

    /// 任务队列名前缀（对齐 picker-cast / picker-key 命名族，NFR-8）
    static let transferQueueLabelPrefix = "picker-transfer-"
    /// 进度轮询队列名前缀（同上命名族；每任务独立队列，避免多任务轮询互相阻塞）
    static let probeQueueLabelPrefix = "picker-transfer-probe-"

    /// 文档性常量：验收指标「进行中 → 终态 ≤ 2 秒」的基准，
    /// 由 waitUntilExit 零时延路径结构性满足，**不用于运行时逻辑**（NFR-1/6）
    static let terminalStateDeadline: TimeInterval = 2.0
}

// MARK: - 中文文案常量（模式对齐 BannerText）

enum TransferCardText {

    // 方向文案（FT-PROG-1）
    static let pushRunningFormat = "正在推送到 %@…"
    static let pullRunningFormat = "正在从 %@ 拉取…"

    // 成功文案（FT-NOTIF-1）
    static let pushSucceededFormat = "已推送到 %@ · %d 个文件"
    static let pullSucceededFormat = "已拉取到下载文件夹 · %@"

    // 失败文案（FT-NOTIF-2/3）
    static let pushFailed = "推送失败"
    static let pullFailed = "拉取失败"
    static let partialFailureFormat = "%d 个成功 · %d 个失败"

    // 取消文案（D-CANCEL：取消是预期内终止，非错误，不复用失败文案）
    static let pushCancelled = "推送已取消"
    static let pullCancelled = "拉取已取消"
    /// 进行中卡片的取消按钮标题（AC-20 纯文字，不引入 SF Symbol）
    static let cancelButton = "取消"

    // 受理拒绝与提示（design 2.2.2 异常映射表逐字）
    static let rejectedOffline = "该设备当前离线，无法接收文件"
    static let rejectedDeviceBusy = "该设备正在传输文件，请稍候"
    static let rejectedGlobalLimit =
        "已有 \(TransferConstants.maxConcurrentTransfers) 个传输在进行，请稍后再试"

    // 失败原因短语（FT-NOTIF-4）
    static let deviceDisconnected = "设备连接中断"
    static let deviceStorageFull = "设备存储空间不足"
    static let macDiskFull = "Mac 磁盘空间不足"
    static let deviceUnreachable = "设备当前不可达"
    static let adbUnavailable = "adb 不可用"
    static let directoryMissingFormat = "设备上没有该目录：%@"
    static let directoryMissingNoName = "设备上没有该目录"
    static let directoryEmpty = "目录为空，没有拉取到文件"

    // 卡片区展示（FT-PROG-2/3）
    static let batchProgressFormat = "第 %d/%d 个"
    static let overflowSummaryFormat = "+%d 个传输中"
    static let indeterminateProgress = "传输中…"

    // 行内状态（FT-PROG-6，D15）
    static let transferringRowStatus = "传输中"
}
