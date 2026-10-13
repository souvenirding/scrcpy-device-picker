// DeviceListViewModel.swift - 主窗口 ViewModel（承接 app.js 全部交互时序，design 2.4.1 / 2.1.4 / 2.6）
//
// D1 决策：ObservableObject + @Published（Combine），维持 macOS 13.0，不使用 @Observable 宏。
// 线程模型（design 2.1.3）：命令主线程入口 → 投屏串行队列 picker-cast 执行服务调用 →
// 结果经 DispatchQueue.main.async 回主线程发布；后台线程不触碰 @Published。
// toast 文案/时长与 banner 文案逐字对齐 spec 5.10 与原版 app.js（1.2.5 时序基线）。
import AppKit
import Foundation


// MARK: - ServiceError 展示映射（对齐原 HTTP 版错误字符串，spec 6.2 约束 1）

extension ServiceError {
    /// banner「按键发送失败：<reason>」的 reason（沿用原版机器码字符串，行为对等）
    var displayReason: String {
        switch self {
        case .scrcpyExited(let detail, _): return detail
        case .noTransport: return "no live target for device"
        case .inputInjectBlocked: return "input_inject_blocked"
        case .badKeyEventCode: return "bad keyevent code"
        case .deviceNotFound: return "unknown device"
        }
    }
}

// MARK: - 主窗口 ViewModel

@MainActor
final class DeviceListViewModel: ObservableObject {

    // MARK: 可观察状态（design 2.4.1 属性表，初始值逐项对齐）

    @Published var rows: [DeviceRowVM] = []                 // 设备行快照（5.1 七列数据源）
    @Published var loading = true                           // 首次刷新未完成（底部"加载中…"）
    @Published var lastRefreshText = "—"                    // 无刷新记录显示 "—"（5.1 规则 10）
    @Published var banner: String?                          // 常驻横幅，单槽位新替旧（5.10 规则 1）
    @Published var toast: ToastState?                       // 一次性进度卡片，单槽位新替旧（5.10 规则 2/3）
    @Published var castingKeys: Set<String> = []            // 行内"启动中"集合；刷新重绘不抹除（5.4 规则 1）
    @Published var castBusy = false                         // 全局启动锁（5.3 规则 8）
    @Published var aliasDialog: AliasDialogState?           // 备注名对话框（非 nil 即呈现 alert）
    @Published var removeConfirmKey: String?                // 移除确认对话框（非 nil 即呈现 confirmationDialog）
    @Published var wirelessLabel = "无线/扫描：关闭"         // 状态标识（5.2 规则 5；服务恒 false，常量呈现）

    private let service: DeviceServiceProtocol
    /// 投屏串行队列（design 2.1.3：同一时刻至多一个投屏请求在服务层执行，与互斥检查双保险）
    private let castQueue = DispatchQueue(label: "picker-cast")
    /// 按键串行队列（M2：与 castQueue 分离——waitForWindow 在 castQueue 轮询最长
    /// 20s，期间右键按键不再被投屏等待阻塞；对齐 NavBarViewModel 的独立 keyQueue 模式）
    private let keyQueue = DispatchQueue(label: "picker-key")
    /// 当前显示的"刷新异常"横幅文本（异常消除后精确清除，不误伤其他横幅，M3）
    private var refreshErrorBanner: String?
    /// toast 自动消失工作项（新替旧时取消旧计时器，5.10.3 场景 1）
    private var toastHideWork: DispatchWorkItem?

    init(service: DeviceServiceProtocol) {
        self.service = service
    }

    // MARK: 生命周期与刷新

    /// 装配完成入口：订阅完成回调 + 触发首轮刷新（design 2.4.1 命令表）。
    func start() {
        // 回调闭包继承本方法的 @MainActor 隔离；服务层保证经主队列调用（design 2.1.3）
        service.onRefreshCompleted = { [weak self] payload in
            self?.handleRefreshPayload(payload)
        }
        refresh(deep: false)
    }

    /// 手动刷新/深度刷新（5.2 规则 3/4）：置唤醒标志立即返回，完成回调更新。
    func refresh(deep: Bool) {
        service.requestRefresh(deep: deep)
    }

    /// 完成回调：更新 rows/lastRefreshText/loading；banner 联动（spec 5.10 规则 1）。
    func handleRefreshPayload(_ payload: RefreshPayload) {
        rows = payload.snapshot.rows
        loading = false                       // 仅首次刷新完成有实际变化（true → false）
        lastRefreshText = formatRefreshTime(payload.snapshot.lastRefresh)
        if payload.status.adbMissing {
            refreshErrorBanner = nil
            showBanner(BannerText.adbMissing)
        } else if !payload.snapshot.error.isEmpty {
            // 刷新异常横幅（M3：如 adb 二进制不可执行）——error 非空优先于恢复清理
            refreshErrorBanner = payload.snapshot.error
            showBanner(payload.snapshot.error)
        } else if banner == BannerText.adbMissing || banner == refreshErrorBanner {
            // adb 恢复 / 异常消除 → 隐藏（只撤刷新类横幅，不误伤投屏失败等其他横幅）
            refreshErrorBanner = nil
            hideBanner()
        }
    }

    // MARK: 投屏命令（design 2.1.4 投屏状态机 / 2.6.1 全流程）

    /// 投屏命令：互斥检查 → 后台 requestCast → 按 CastResult 分支 → 成功进入 waitForWindow。
    func cast(key: String, mode: CastMode, noClipboard: Bool = false, force: Bool = false) {
        let name = displayName(of: key)
        // 行级互斥（spec 5.3 规则 7）
        if castingKeys.contains(key) {
            showToast(.warn, "这台设备正在启动投屏…", "\(name) · 请稍候", ToastDuration.warnMutex)
            return
        }
        // 全局互斥（spec 5.3 规则 8）
        if castBusy {
            showToast(.warn, "正在启动另一台设备的投屏…", "稍等一下再点 \(name)", ToastDuration.warnMutex)
            return
        }
        castBusy = true
        castingKeys.insert(key)
        hideBanner()
        showToast(.running, "正在启动投屏…", "\(name) · 正在连接设备", nil)
        // nonisolated(unsafe)：服务层内部 NSLock 线程安全（design 2.2.2 B），
        // 协议本体冻结无法标注 Sendable，由调用方担保跨队列捕获安全
        nonisolated(unsafe) let service = self.service
        castQueue.async { [weak self] in
            let result = service.requestCast(key: key, mode: mode,
                                             noClipboard: noClipboard, force: force)
            DispatchQueue.main.async {
                self?.handleCastResult(result, key: key, name: name)
            }
        }
    }

    /// CastResult 四分支（主线程；design 2.1.4 Starting → Reused/Failed/Waiting）。
    private func handleCastResult(_ result: CastResult, key: String, name: String) {
        switch result {
        case .already:
            // Reused：banner 复用说明 + ok toast 2.6s（spec 5.3 规则 9）
            showBanner(BannerText.reused)
            showToast(.ok, "已复用现有投屏窗口", name, ToastDuration.reused)
            endCast(key: key)
        case .noTransport:
            // Failed：banner 无通道指引 + err toast 6s（spec 5.3.3 场景 1）
            showBanner(BannerText.noTransport())
            showToast(.err, "没有可用通道", "\(name) · adb 当前没列出这台设备", ToastDuration.errorShort)
            endCast(key: key)
        case .exited(let detail, let target, _):
            // Failed：banner 失败详情 + err toast 8s（spec 5.3.3 场景 2；detail 非空由服务层保证）
            showBanner(BannerText.castExited(target: target, detail: detail))
            showToast(.err, "投屏启动失败", detail, ToastDuration.errorLong)
            endCast(key: key)
        case .started:
            // Waiting：进入等待窗口轮询（castingKeys/castBusy 保持，轮询结束才复位）
            waitForWindow(key: key, name: name)
        }
    }

    /// waitForWindow 等待结果（design 2.1.4 Waiting 态四个出口）
    private enum WaitOutcome {
        case windowOpened      // ready == true → Succeeded
        case processDied       // running == false → Failed（中途退出）
        case fallbackSuccess   // elapsed < 0 或 ≥ 6s → Succeeded（兜底/孤儿，spec 5.4 规则 4）
        case timedOut          // 20s 上限 → Timeout（不报错，spec 5.3.3 场景 5）
    }

    /// 等待窗口出现：0.4s 间隔轮询 castProgress（投屏串行队列），每轮回主线程更新副标题。
    /// 判定顺序对齐原版 app.js:211-213（running → ready → 兜底）：
    /// 进程已退出时即使日志残留就绪特征也判失败（窗口必然已消失）。
    private func waitForWindow(key: String, name: String) {
        nonisolated(unsafe) let service = self.service
        castQueue.async { [weak self] in
            let t0 = Date()
            let limit: TimeInterval = 20        // 慢机器/首次推 server 的兜底
            let fallback: TimeInterval = 6      // 日志特征万一变了，也不能让用户一直转圈
            var outcome: WaitOutcome?
            while Date().timeIntervalSince(t0) < limit {
                let st = service.castProgress(key: key)
                if !st.running { outcome = .processDied; break }
                if st.ready { outcome = .windowOpened; break }
                if st.elapsed < 0 || st.elapsed >= fallback { outcome = .fallbackSuccess; break }
                let waited = Date().timeIntervalSince(t0)
                DispatchQueue.main.async {
                    self?.updateWaitSubtitle(name: name, waited: waited)
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            let final = outcome ?? .timedOut
            DispatchQueue.main.async {
                self?.handleWaitOutcome(final, key: key, name: name)
            }
        }
    }

    /// 等待副标题实时更新（spec 5.4 规则 2；格式对齐原版 "已等待 x.xs"）。
    private func updateWaitSubtitle(name: String, waited: TimeInterval) {
        let seconds = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), waited)
        toast?.subtitle = "\(name) · 已等待 \(seconds)s"
    }

    /// Waiting 态出口分支（主线程；design 2.1.4 Waiting → Succeeded/Failed/Timeout）。
    private func handleWaitOutcome(_ outcome: WaitOutcome, key: String, name: String) {
        switch outcome {
        case .windowOpened, .fallbackSuccess:
            // Succeeded：清 banner + ok toast 2.2s（spec 5.4 规则 5；兜底成功同样清）
            hideBanner()
            showToast(.ok, "投屏窗口已打开", name, ToastDuration.windowOpened)
        case .processDied:
            // Failed：banner 中途退出 + err toast 8s（spec 5.3.3 场景 4）
            showBanner(BannerText.castDied)
            showToast(.err, "投屏进程已退出", "\(name) · 可试「强制重新投屏」", ToastDuration.errorLong)
        case .timedOut:
            // Timeout：不报错，warn toast 6s（spec 5.3.3 场景 5；无 banner）
            showToast(.warn, "投屏还在启动中",
                      "\(name) · 若一直没窗口，试试「强制重新投屏」", ToastDuration.errorShort)
        }
        endCast(key: key)
    }

    /// 投屏流程复位：每个退出分支必经（成功/失败/复用/超时），幂等可重入
    /// （spec 5.4 规则 6"避免幽灵投屏中"，design 2.1.4 分支要点 1）。
    private func endCast(key: String) {
        castingKeys.remove(key)
        castBusy = false
    }

    // MARK: 按键命令（spec 5.5）

    /// 右键单发按键：后台服务调用（独立 keyQueue，M2）→ 成功静默清 banner；被拒显示小米指引。
    func sendKey(key: String, code: Int) {
        nonisolated(unsafe) let service = self.service
        keyQueue.async { [weak self] in
            let result = service.sendKey(key: key, code: code)
            DispatchQueue.main.async {
                self?.handleSendKeyResult(result)
            }
        }
    }

    private func handleSendKeyResult(_ result: NavResult) {
        switch result {
        case .sent:
            hideBanner()                                   // 成功静默（spec 5.5 规则 4）
        case .blocked:
            showBanner(BannerText.injectBlocked)           // 小米/MIUI/HyperOS 指引（5.5.3 场景 1）
        case .failure(let error):
            showBanner(BannerText.keyFailed(error.displayReason))   // 5.5.3 场景 2/3
        }
    }

    // MARK: 备注名（spec 5.6 / design 2.6.2 三分支）

    /// 打开备注名对话框：预填当前显示名（spec 5.6 规则 1）。
    func beginAlias(key: String) {
        aliasDialog = AliasDialogState(key: key, initialText: displayName(of: key))
    }

    /// 确认保存：非空=保存 / 空串=清除 → setAlias → 立即刷新反映（spec 5.6 规则 2/3）。
    func confirmAlias(_ text: String) {
        guard let dialog = aliasDialog else { return }
        aliasDialog = nil
        service.setAlias(key: dialog.key, alias: text)
        refresh(deep: false)
    }

    /// 取消不动（spec 5.6 规则 4；Esc 由 alert 天然等同取消）。
    func cancelAlias() {
        aliasDialog = nil
    }

    // MARK: 移除（spec 5.7 / design 2.6.3 两分支）

    func beginRemove(key: String) {
        removeConfirmKey = key
    }

    /// 确认移除：删缓存条目（含备注名）→ 立即刷新（spec 5.7 规则 2）。
    func confirmRemove() {
        guard let key = removeConfirmKey else { return }
        removeConfirmKey = nil
        service.removeDevice(key: key)
        refresh(deep: false)
    }

    /// 取消保留（spec 5.7 规则 3）。
    func cancelRemove() {
        removeConfirmKey = nil
    }

    // MARK: 地址复制（spec 5.8）

    /// 复制地址：NSPasteboard 写入；空地址不写、不清空剪贴板（spec 5.8 规则 2）。
    func copyAddress(key: String) {
        guard let addr = rows.first(where: { $0.key == key })?.addr, !addr.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(addr, forType: .string)
    }

    // MARK: 断开无线会话（spec 5.7 规则 5）

    /// 断开无线会话：后台服务 → 刷新反映真实状态（失败忽略，spec 5.7.3 场景 1）。
    func disconnectWireless(key: String) {
        nonisolated(unsafe) let service = self.service
        castQueue.async { [weak self] in
            service.disconnectWireless(key: key)
            DispatchQueue.main.async {
                self?.refresh(deep: false)
            }
        }
    }

    // MARK: 提示状态机（design 2.1.4 toast 状态机 / banner 单槽位）

    /// 点击卡片立即关闭（spec 5.10 规则 2）。
    func dismissToast() {
        toastHideWork?.cancel()
        toastHideWork = nil
        toast = nil
    }

    /// banner 单槽位：非空即显示、新替旧（spec 5.10 规则 1）。
    /// internal：NavBarViewModel 的按键反馈走本槽位（design 2.4.2 说明 1）。
    func showBanner(_ text: String) {
        banner = text
    }

    /// 隐藏 banner（投屏成功/按键成功/adb 恢复时触发，design 2.1.4 banner 状态）。
    func hideBanner() {
        banner = nil
    }

    /// toast 单槽位：新替旧 + 计时器重置；running 态（autoHide=nil）不自动消失（5.10 规则 3）。
    private func showToast(_ phase: ToastPhase, _ title: String, _ subtitle: String,
                           _ autoHide: TimeInterval?) {
        toastHideWork?.cancel()
        toastHideWork = nil
        toast = ToastState(phase: phase, title: title, subtitle: subtitle, autoHide: autoHide)
        guard let autoHide = autoHide else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.toast = nil
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
    }

    // MARK: 私有工具

    /// 显示名：rows 查找，兜底 key（design 2.4.1 cast 示意）。
    private func displayName(of key: String) -> String {
        return rows.first(where: { $0.key == key })?.name ?? key
    }

    /// ISO8601 → "HH:mm:ss"；无记录显示 "—"（spec 5.1 规则 10）。
    private func formatRefreshTime(_ iso: String) -> String {
        guard !iso.isEmpty, let date = isoDate(iso) else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 辅助值类型与常量（design 2.4.1 设计示意）

extension DeviceListViewModel {
    /// toast 卡片状态（对齐 app.js toast() 的 state 参数：''=running/ok/warn/err）
    enum ToastPhase {
        case running, ok, warn, err
    }

    struct ToastState: Equatable {
        let phase: ToastPhase
        let title: String
        var subtitle: String
        let autoHide: TimeInterval?   // nil = 不自动消失（进行中）
    }

    /// 备注名对话框状态（预填当前显示名，spec 5.6 规则 1）
    struct AliasDialogState: Equatable {
        let key: String
        var initialText: String
    }

    /// toast 自动消失时长常量（spec 5.10 规则 3 逐字对齐，杜绝魔法数字）
    enum ToastDuration {
        static let reused: TimeInterval = 2.6          // 成功-复用
        static let windowOpened: TimeInterval = 2.2    // 成功-窗口已打开
        static let errorShort: TimeInterval = 6.0      // 其余错误 / 其余警告
        static let errorLong: TimeInterval = 8.0       // scrcpy 退出 / 中途退出
        static let warnMutex: TimeInterval = 3.0       // 互斥提示
    }

    /// banner 文案常量（spec 5.10 规则 4 逐字，含排错指引不得改写）
    enum BannerText {
        static let adbMissing =
            "未找到 adb：请 `brew install --cask android-platform-tools`，或设置 SCRCPY_TOOL_DIR 指向含 adb 的目录。"
        static func noTransport() -> String {
            "找不到这台设备的可用通道：adb 当前没列出它。插上 USB、或点「深度刷新」重新发现后再投屏。"
        }
        static func castExited(target: String, detail: String) -> String {
            "投屏启动失败（目标 \(target)）：\(detail) —— 可试试右键「强制重新投屏」。"
        }
        static let reused =
            "该设备已在投屏中，已复用现有窗口（关掉旧窗口后可再次投屏，或用右键「强制重新投屏」）。"
        static let castDied =
            "投屏进程启动后中途退出，请用右键「强制重新投屏」再试一次。"
        static let injectBlocked =
            "该设备拒绝了按键注入。小米/MIUI/HyperOS 需在「开发者选项」中额外开启「USB 调试（安全设置）」（可能要求登录小米账号并插入 SIM 卡）；开启后 返回/桌面/多任务/唤醒 即可生效。"
        static func keyFailed(_ reason: String) -> String { "按键发送失败：\(reason)" }
    }
}