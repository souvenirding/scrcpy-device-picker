// DeviceService.swift - 进程内设备服务（原 HTTP 版业务迁移，design 2.2.2 B/C/D）
//
// 迁移说明（design 2.2.2 D 映射表，原 HTTP 版业务已逐条迁入，过渡文件已删除）：
//   * HTTP 传输层（路由分发 / Origin 校验 / 静态资源 / JSON 序列化边界）不迁移
//     （spec 6.3 移除清单 4）；9 条路由业务语义逐条迁入协议方法。
//   * action(op:) 字符串分发拆为 setAlias / removeDevice / disconnectWireless 三显式方法。
//   * 字典行字段访问（as? 解包）全部改 DeviceRowVM 强类型属性。
//   * status() 版本字段改刷新线程组装缓存（design 2.2.2 C2 设计变更，避免主线程
//     子进程卡顿）；AppStatus 无 port 字段（HTTP 层随重构移除）。
//   * 刷新循环新增 paused 暂停态（design 2.1.4 状态机三态）。
// 线程模型（design 2.1.3）：
//   * 刷新线程 "picker-refresh"（stackSize 2MB）承载 refreshLoop / doRefresh / RowBuilder
//     （RowBuilder 仅在刷新线程被调用，design 2.9 R2：不改变调用线程归属）。
//   * onRefreshCompleted 经 DispatchQueue.main.async 回主线程。
//   * 共享状态由单个 NSLock 保护（沿用原版锁纪律）。
import Foundation

// MARK: - 服务协议（design 2.2.2 B；一经实现即冻结，design 2.2.1）

/// 进程内设备服务：原 HTTP 版 9 条路由的业务语义载体。
/// ViewModel 经协议注入（spec 4.4 规则 1 可测试性）；实现类持有
/// Toolchain / Discovery / CastManager（RowBuilder 为无状态静态组装，无需持有）。
protocol DeviceServiceProtocol: AnyObject {
    // MARK: 查询（对应 GET /api/devices、GET /api/status、GET /api/caststate?key=）

    func snapshot() -> DeviceSnapshot
    func status() -> AppStatus
    /// 含副作用：进程不存活时清理该 key 的投屏登记（原 castState 行为，spec 4.2 规则 5）
    func castProgress(key: String) -> CastProgress

    // MARK: 命令（对应 POST /api/cast、/api/nav、/api/refresh、/api/action 三 op）

    /// 阻塞式（内含 1.5s 存活等待与 force 终止缓冲），调用方须在后台队列执行
    func requestCast(key: String, mode: CastMode, noClipboard: Bool, force: Bool) -> CastResult
    func sendKey(key: String, code: Int) -> NavResult
    /// 受理确认：置唤醒标志立即返回（重复点击天然合并，spec 5.2.3 场景 2）
    func requestRefresh(deep: Bool)
    /// 空串 = 清除备注名
    func setAlias(key: String, alias: String)
    func removeDevice(key: String)
    /// 现算目标 → adb disconnect；失败忽略
    func disconnectWireless(key: String)

    // MARK: 生命周期与通知

    /// 起后台刷新线程（替代原 start() 的端口绑定部分，线程参数保留）
    func startRefreshLoop()
    /// 置 stop 标志（原 stopAll，刷新线程在下一个 0.3s 步进内退出）
    func stopRefreshLoop()
    /// 新增：主窗口可见性联动（spec 5.2 规则 2；Paused 态不执行 adb devices）
    func setRefreshPaused(_ paused: Bool)
    /// 刷新完成回调（服务层保证在主线程调用，design 2.1.3 线程模型）
    var onRefreshCompleted: ((RefreshPayload) -> Void)? { get set }
}

// MARK: - 实现

final class DeviceService: DeviceServiceProtocol {
    let tools: Toolchain
    let discovery: Discovery
    let casts: CastManager

    private let lock = NSLock()
    // 共享状态（沿用原版字段 + 新增 paused / statusCache / 完成回调）
    private var rows: [DeviceRowVM] = []
    private var lastRefresh = ""
    private var lastError = ""
    private var adbMissing = false
    private var statusCache = AppStatus(adbPath: "", adbVersion: "", scrcpyPath: "",
                                        scrcpyVersion: "", adbMissing: false,
                                        lastRefresh: "", wirelessEnabled: false)
    private var forceNow = false
    private var forceDeep = false
    private var stop = false
    private var paused = false
    private var _onRefreshCompleted: ((RefreshPayload) -> Void)?

    init(tools: Toolchain) {
        self.tools = tools
        self.discovery = Discovery(tools: tools)
        self.casts = CastManager(tools: tools)
    }

    // MARK: 生命周期

    func startRefreshLoop() {
        let t = Thread { [weak self] in self?.refreshLoop() }
        t.stackSize = 1 << 21
        t.name = "picker-refresh"
        t.start()
    }

    func stopRefreshLoop() {
        lock.lock()
        stop = true
        lock.unlock()
    }

    func setRefreshPaused(_ paused: Bool) {
        lock.lock()
        self.paused = paused
        lock.unlock()
    }

    var onRefreshCompleted: ((RefreshPayload) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _onRefreshCompleted
        }
        set {
            lock.lock()
            _onRefreshCompleted = newValue
            lock.unlock()
        }
    }

    // MARK: 查询

    /// 最近一次刷新的设备行快照（含离线合并行）与刷新时间（原 snapshotRows + 组装）。
    func snapshot() -> DeviceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return DeviceSnapshot(rows: rows, lastRefresh: lastRefresh, error: lastError)
    }

    /// 应用状态（原 status 搬移；无 port 字段）。
    /// 只读缓存：版本字段由刷新线程在 doRefresh 组装（design 2.2.2 C2 设计变更），
    /// 避免主线程每次查询都跑 adb/scrcpy 子进程。
    func status() -> AppStatus {
        lock.lock(); defer { lock.unlock() }
        return statusCache
    }

    /// 投屏状态查询（原 castState；无登记时 pid=0、running=false、elapsed=-1）。
    func castProgress(key: String) -> CastProgress {
        let st = casts.state(for: key)
        var alive = false
        var elapsed: TimeInterval = -1
        if let s = st {
            alive = casts.isAlive(s.pid)
            // 副作用保留：登记存在但进程不存活 → 清理该 key 投屏登记
            // （design 1.2.1 语义红线；spec 4.2 规则 5"避免幽灵投屏中"的机制基础）
            if !alive { casts.clear(key) }
            if let started = s.started { elapsed = Date().timeIntervalSince(started) }
        }
        let ready = st.map { casts.isReady(logPath: $0.logPath) } ?? false
        return CastProgress(key: key, pid: st?.pid ?? 0, running: alive, ready: ready, elapsed: elapsed)
    }

    // MARK: 命令 - 投屏（原 cast()，design 2.2.2 C4 七步语义链）

    func requestCast(key: String, mode: CastMode, noClipboard: Bool, force: Bool) -> CastResult {
        // ① 快照行查找：Key == key 且非离线（离线设备双击被忽略的服务端防线，
        //    design 1.2.1 红线 1）；未命中 → 无可用通道
        guard let row = snapshot().rows.first(where: { $0.key == key && !$0.offline }) else {
            return .noTransport
        }

        // ② 模式分支：各自检查通道存在性后才 resolveTarget（红线 2）
        var target: String?
        switch mode {
        case .usb:
            if row.usb { target = discovery.resolveTarget(key: key, usbSerial: row.usbSerial) }
        case .tls:
            if !row.tls.isEmpty { target = discovery.resolveTarget(key: key, tls: row.tls) }
        case .tcp:
            if !row.tcp5555.isEmpty { target = discovery.resolveTarget(key: key, tcp5555: row.tcp5555) }
        case .auto:
            target = discovery.resolveTarget(key: key, preferred: row.preferred,
                                             usbSerial: row.usbSerial, tls: row.tls,
                                             tcp5555: row.tcp5555)
        }
        guard let t = target else { return .noTransport }

        // ③ 复用/认领次序（红线 3）：登记 pid 存活 → 复用；否则 adopt 认领遗留进程；
        //    认领失败 clear
        var existing: Int32 = casts.state(for: key)?.pid ?? 0
        if existing == 0 || !casts.isAlive(existing) {
            existing = casts.adopt(key: key, target: t) ?? 0
            if existing == 0 { casts.clear(key) }
        }

        // ④ already 与 force 互斥：非强制复用现有进程，不重开窗口
        if existing != 0 && !force {
            return .already(pid: existing, target: t)
        }

        // ⑤ 强制重开：kill（CastManager.kill 内含 SIGTERM→0.3s→SIGKILL）
        //    + 0.4s 缓冲 + clear 后重新拉起
        if existing != 0 && force {
            casts.kill(existing)
            Thread.sleep(forTimeInterval: 0.4)
            casts.clear(key)
        }

        // ⑥ 启动失败（scrcpy 可执行文件不存在 / 日志文件创建失败）→ 清理并返回失败详情
        guard let started = casts.start(key: key, target: t, noClipboard: noClipboard) else {
            casts.clear(key)
            return .exited(detail: "无法启动 scrcpy（未找到可执行文件？）", target: t, pid: 0)
        }

        // ⑦ 拉起后 1.5s 存活检查：目标不可用时 scrcpy 会立刻带着报错退出
        Thread.sleep(forTimeInterval: 1.5)
        if casts.isAlive(started.pid) {
            return .started(pid: started.pid, target: t, logPath: started.logPath)
        }
        let detail = casts.logSummary(logPath: started.logPath)
        casts.clear(key)
        return .exited(detail: detail.isEmpty ? "scrcpy 启动后立即退出" : detail,
                       target: t, pid: started.pid)
    }

    // MARK: 命令 - 按键（原 nav()，design 2.2.2 C5）

    func sendKey(key: String, code: Int) -> NavResult {
        // 码域校验前置（1~500，spec 4.3 规则 3）：越界直接拒绝，不执行 adb
        // （design 2.2.2 C5 设计变更：原版校验在目标现算之后，顺序无行为差异，
        //  前置可省一次 adb devices 调用）
        guard code >= 1, code <= 500 else { return .failure(.badKeyEventCode) }

        // 行查找（在线）
        guard let row = snapshot().rows.first(where: { $0.key == key && !$0.offline }) else {
            return .failure(.noTransport)
        }
        // 目标现算（spec 4.3 规则 2：绝不信任 UI 传入的地址串）
        guard let t = discovery.resolveTarget(key: key, preferred: row.preferred,
                                              usbSerial: row.usbSerial, tls: row.tls,
                                              tcp5555: row.tcp5555) else {
            return .failure(.noTransport)
        }
        let out = tools.adbText(["-s", t, "shell", "input", "keyevent", String(code)])
        if reTest("INJECT_EVENTS|SecurityException", out) {
            // 稳定错误码：小米/MIUI/HyperOS 未开"USB 调试（安全设置）"，指引由 ViewModel 呈现
            return .blocked(code: code, target: t)
        }
        return .sent(code: code, target: t)
    }

    // MARK: 命令 - 刷新请求（原 refresh()，design 2.2.2 C6）

    func requestRefresh(deep: Bool) {
        // 置唤醒标志立即返回；标志置位语义天然合并重复点击（spec 5.2.3 场景 2）。
        // forceDeep 直接赋值（沿用原版语义：每次请求重置深度标志）。
        lock.lock()
        forceDeep = deep
        forceNow = true
        lock.unlock()
    }

    // MARK: 命令 - 备注名（原 action op=alias，design 2.2.2 C7）

    func setAlias(key: String, alias: String) {
        var c = ConfigStore.shared.device(key) ?? DeviceCache()
        c.Alias = alias                 // 空串 = 清除
        if c.ts == nil { c.ts = isoNow() }
        // 落盘失败静默（ConfigStore.save 内 try? 容错，spec 5.6.3 场景 1：内存态已更新）
        ConfigStore.shared.setDevice(key, c)
    }

    // MARK: 命令 - 移除设备（原 action op=forget，design 2.2.2 C8）

    func removeDevice(key: String) {
        ConfigStore.shared.removeDevice(key)
    }

    // MARK: 命令 - 断开无线会话（原 action op=disconnect，design 2.2.2 C9）

    func disconnectWireless(key: String) {
        // 查行含离线行（design 1.2.1 红线 5）：resolveTarget 实时校验会拦住
        // 已不在线的传输——行为等价于"忽略失败，刷新反映真实状态"
        guard let row = snapshot().rows.first(where: { $0.key == key }) else { return }
        guard let t = discovery.resolveTarget(key: key, preferred: row.preferred,
                                              usbSerial: row.usbSerial, tls: row.tls,
                                              tcp5555: row.tcp5555) else { return }
        // endpoint 不含 ":" 时 Discovery.disconnect 内部跳过；失败忽略
        discovery.disconnect(t)
    }

    // MARK: 后台刷新（design 2.1.4 状态机：Running / Paused / Stopped）

    private func refreshLoop() {
        while true {
            lock.lock()
            let shouldStop = stop
            let isPaused = paused
            lock.unlock()
            if shouldStop { return }

            if isPaused {
                // Paused 态：0.3s 步进检查，不执行 adb devices（spec 5.2 规则 2）。
                // 不消耗 forceNow/forceDeep —— 暂停期间的唤醒请求保留，恢复后生效
                // （design 2.1.4"唤醒标志不丢失"）。
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }

            // Running 态：消耗唤醒标志（暂停期间置位的标志在此生效，不丢失）
            lock.lock()
            let deep = forceDeep
            forceDeep = false
            forceNow = false
            lock.unlock()

            autoreleasepool {
                doRefresh(deep: deep)
            }

            // 空闲最多 10s；手动刷新 / 暂停 / 停止都能在 0.3s 步进内立刻唤醒
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                lock.lock()
                let wake = forceNow || stop || paused
                lock.unlock()
                if wake { break }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    private func doRefresh(deep: Bool) {
        // 刷新失败判定（spec 5.2.3 场景 1 的可检测子集）：adb 已解析但二进制
        // 不可执行（工具目录被移走/损坏）→ 本轮作废，不覆盖上一轮有效快照，
        // error 承载异常文本；下个周期重试。仍发完成回调（携带上一轮快照），
        // 手动刷新的"及时反映"不落空。
        if tools.adbResolved && !FileManager.default.isExecutableFile(atPath: tools.adbPath) {
            lock.lock()
            lastError = "adb 调用失败：\(tools.adbPath) 不可执行"
            lock.unlock()
            notifyRefreshCompleted()
            return
        }

        let inv = discovery.inventory(deep: deep, allowWireless: false)
        // RowBuilder 仅在刷新线程被调用（design 2.9 R2：不改变调用线程归属）
        let newRows = RowBuilder.build(online: inv)
        let now = isoNow()
        // 版本字段在刷新线程组装（design 2.2.2 C2：status() 只读缓存，
        // 避免主线程子进程卡顿；语义等价——原版前端也是 10s 轮询一次）。
        // 版本探测缓存（M4）：版本子进程开销大，仅首轮（缓存为空）或 adb
        // 解析状态翻转时重新探测，其余轮次复用缓存——版本不随刷新变化。
        lock.lock()
        let cachedStatus = statusCache
        lock.unlock()
        let resolvedNow = tools.adbResolved
        let needProbe = cachedStatus.adbVersion.isEmpty || resolvedNow != !cachedStatus.adbMissing
        let newStatus = AppStatus(
            adbPath: tools.adbPath,
            adbVersion: needProbe ? tools.adbVersion() : cachedStatus.adbVersion,
            scrcpyPath: tools.scrcpyPath,
            scrcpyVersion: needProbe ? tools.scrcpyVersion() : cachedStatus.scrcpyVersion,
            adbMissing: !resolvedNow,
            lastRefresh: now,
            wirelessEnabled: false
        )
        lock.lock()
        rows = newRows
        lastRefresh = now
        adbMissing = !tools.adbResolved
        lastError = ""
        statusCache = newStatus
        lock.unlock()
        notifyRefreshCompleted()
    }

    /// 刷新完成通知：组装载荷后经主队列回调（design 2.1.3 线程模型）。
    private func notifyRefreshCompleted() {
        lock.lock()
        let payload = RefreshPayload(
            snapshot: DeviceSnapshot(rows: rows, lastRefresh: lastRefresh, error: lastError),
            status: statusCache
        )
        let cb = _onRefreshCompleted
        lock.unlock()
        guard let cb = cb else { return }
        DispatchQueue.main.async { cb(payload) }
    }
}