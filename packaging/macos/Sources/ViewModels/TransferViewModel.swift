// TransferViewModel.swift - 传输状态与命令中枢（design 2.1.2 D-VM / 2.2.2 接口组 2 / 2.4.5 / 2.4.8 / 2.6）
//
// D-VM 决策：新建独立 ViewModel，不扩展 DeviceListViewModel —— 后者 toast 是
// 「新替旧」单槽位模型，而传输要求多卡片堆叠共存（FT-PROG-3）；两者经同一
// DeviceServiceProtocol 实例共享设备快照，投屏零回归（DeviceListViewModel 零改动）。
//
// 线程归属（design 2.6 线程归属清单）：全部 @Published 状态仅主线程读写，
// @MainActor 隔离保障；adb 调用在服务层后台队列，进度/终态经主队列回发。
import Foundation

@MainActor
final class TransferViewModel: ObservableObject {

    // MARK: 可观察状态（design 2.1.2 组件表）

    /// 右下角传输卡片堆叠区（入列序即数组序，FT-PROG-3）
    @Published var transferCards: [TransferCardState] = []
    /// 行内「传输中」设备集合（平行复制 castingKeys 的「刷新重绘不抹除」模式，FT-PROG-6）
    @Published var transferringKeys: Set<String> = []
    /// 拖拽悬停高亮单槽位（同一时刻只悬停一行，FT-DRAG-6）
    @Published var dropTargetedKey: String?

    private let service: DeviceServiceProtocol
    private let manager: TransferServiceProtocol

    /// 每卡片独立自动消失计时（多卡片版 toastHideWork，design 2.4.8）
    private var cardTimers: [TransferCardID: DispatchWorkItem] = [:]
    /// 拉取任务 → 快捷目录名（终态成功文案需要目录名）
    private var taskDirectoryNames: [TransferTaskID: String] = [:]

    init(service: DeviceServiceProtocol, manager: TransferServiceProtocol) {
        self.service = service
        self.manager = manager
    }

    // MARK: 生命周期

    /// 装配完成入口：订阅服务层进度/终态回调（对齐 DeviceListViewModel.start() 模式）。
    func start() {
        manager.onProgress = { [weak self] update in
            self?.handleProgress(update)
        }
        manager.onFinal = { [weak self] update in
            self?.handleFinal(update)
        }
    }

    // MARK: - 命令入口（design 2.2.2 接口组 2）

    /// 推送命令（拖拽聚合结果与文件面板确认共用）。
    func pushFiles(key: String, urls: [URL]) {
        guard !urls.isEmpty else { return }
        let name = displayName(of: key)
        let result = manager.startPush(key: key, urls: urls)
        switch result {
        case .started(let taskID):
            insertRunningCard(taskID: taskID, direction: .push, deviceName: name,
                              fileName: urls[0].lastPathComponent,
                              fileIndex: 1, totalFiles: urls.count)
            transferringKeys.insert(key)
        case .rejectedOffline, .rejectedDeviceBusy, .rejectedGlobalLimit, .failedAdbMissing:
            // 拒绝类提示：warn 卡片 3s（design 2.2.2 异常映射表）
            insertNoticeCard(text: warnText(for: result),
                             phase: .warn,
                             duration: TransferConstants.noticeCardDuration)
        case .failedUnreachable:
            insertNoticeCard(text: TransferCardText.deviceUnreachable,
                             phase: .err,
                             duration: TransferConstants.failureCardDuration)
        case .failed(let reason):
            insertNoticeCard(text: reason.displayText,
                             phase: .err,
                             duration: TransferConstants.failureCardDuration)
        }
    }

    /// 快捷目录拉取命令（子菜单三项共用，点选即拉取，无二次确认）。
    func pullQuickDirectory(key: String, directory: QuickPullDirectory) {
        let name = displayName(of: key)
        let result = manager.startPull(key: key, directory: directory)
        switch result {
        case .started(let taskID):
            taskDirectoryNames[taskID] = directory.displayName
            insertRunningCard(taskID: taskID, direction: .pull, deviceName: name,
                              fileName: directory.displayName,
                              fileIndex: 1, totalFiles: 1)
            transferringKeys.insert(key)
        case .rejectedOffline, .rejectedDeviceBusy, .rejectedGlobalLimit, .failedAdbMissing:
            insertNoticeCard(text: warnText(for: result),
                             phase: .warn,
                             duration: TransferConstants.noticeCardDuration)
        case .failedUnreachable:
            insertNoticeCard(text: TransferCardText.deviceUnreachable,
                             phase: .err,
                             duration: TransferConstants.failureCardDuration)
        case .failed(let reason):
            insertNoticeCard(text: reason.displayText,
                             phase: .err,
                             duration: TransferConstants.failureCardDuration)
        }
    }

    /// onDrop perform 回调：异步聚合全部文件 URL → 一次投放 = 一个批量任务。
    /// 返回 true 表示接收本次投放；全部加载失败（0 个 URL）静默忽略（对齐 FT-DRAG-5 精神）。
    func handleDrop(key: String, providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return true }
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [Int: URL] = [:]
        for (offset, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                if let url = object {
                    lock.lock()
                    loaded[offset] = url
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            // 按投放顺序还原（FT-DRAG-2「按文件顺序逐一推送」）
            let urls = loaded.keys.sorted().compactMap { loaded[$0] }
            guard !urls.isEmpty else { return }
            self?.pushFiles(key: key, urls: urls)
        }
        return true
    }

    /// 取消卡片对应的进行中传输（D-CANCEL）。
    /// 仅 running 卡片可取消（有 taskID）；卡片不在此处改写，
    /// 由服务层 .cancelled 终态回调驱动转态，保证「卡片状态 ≡ 服务层状态」。
    func cancelTransfer(cardID: TransferCardID) {
        guard let card = transferCards.first(where: { $0.id == cardID }),
              let taskID = card.taskID else { return }
        manager.cancel(taskID: taskID)
    }

    /// 点击卡片立即关闭（FT-NOTIF-1/2）。
    func dismissCard(id: TransferCardID) {
        if let taskID = transferCards.first(where: { $0.id == id })?.taskID {
            taskDirectoryNames.removeValue(forKey: taskID)
        }
        cancelTimer(for: id)
        transferCards.removeAll { $0.id == id }
    }

    /// 拖拽悬停态写入（onDrop isTargeted Binding 驱动）；nil = 离开任何行。
    func setDropTargeted(_ key: String?) {
        dropTargetedKey = key
    }

    // MARK: - 服务层回调（主线程）

    private func handleProgress(_ update: TransferProgressUpdate) {
        guard let index = transferCards.firstIndex(where: { $0.taskID == update.taskID }) else { return }
        let card = transferCards[index]
        transferCards[index] = TransferCardState(
            id: card.id,
            taskID: card.taskID,
            phase: .running,
            title: card.title,
            subtitle: fileSubtitle(fileName: update.fileName,
                                   fileIndex: update.fileIndex,
                                   totalFiles: update.totalFiles),
            progress: TransferProgressSnapshot(fileIndex: update.fileIndex,
                                               totalFiles: update.totalFiles,
                                               fileName: update.fileName,
                                               percent: update.percent))
    }

    private func handleFinal(_ update: TransferFinalUpdate) {
        // 行内状态恢复（进程退出驱动，天然 ≤ 2s 满足 AC-15）
        transferringKeys.remove(update.deviceKey)
        guard let index = transferCards.firstIndex(where: { $0.taskID == update.taskID }) else { return }
        let cardID = transferCards[index].id
        let name = displayName(of: update.deviceKey)

        var phase: DeviceListViewModel.ToastPhase = .ok
        var title = ""
        var subtitle = ""
        var duration = TransferConstants.successCardDuration

        switch update.outcome {
        case .succeeded(let fileCount):
            phase = .ok
            duration = TransferConstants.successCardDuration
            title = update.direction == .push
                ? String(format: TransferCardText.pushSucceededFormat, name, fileCount)
                : String(format: TransferCardText.pullSucceededFormat,
                         taskDirectoryNames[update.taskID] ?? "")
        case .partialFailure(let successCount, let failureCount, let firstFailure):
            phase = .warn
            duration = TransferConstants.failureCardDuration
            title = String(format: TransferCardText.partialFailureFormat, successCount, failureCount)
            subtitle = firstFailure.displayText
        case .cancelled:
            // 用户主动取消：warn 相位、3s，不复用失败文案（D-CANCEL）
            phase = .warn
            duration = TransferConstants.noticeCardDuration
            title = update.direction == .push
                ? TransferCardText.pushCancelled
                : TransferCardText.pullCancelled
        case .failed(let reason):
            if case .directoryEmpty = reason {
                // 空目录不是失败：warn 呈现、3s（design 2.4.7 要点 3）
                phase = .warn
                duration = TransferConstants.noticeCardDuration
                title = reason.displayText
            } else {
                phase = .err
                duration = TransferConstants.failureCardDuration
                title = update.direction == .push
                    ? TransferCardText.pushFailed
                    : TransferCardText.pullFailed
                subtitle = reason.displayText
            }
        }

        transferCards[index] = TransferCardState(id: cardID, taskID: update.taskID,
                                                 phase: phase, title: title,
                                                 subtitle: subtitle, progress: nil)
        taskDirectoryNames.removeValue(forKey: update.taskID)
        scheduleRemoval(cardID: cardID, after: duration)
    }

    // MARK: - 卡片入列与计时（design 2.4.8）

    private func insertRunningCard(taskID: TransferTaskID,
                                   direction: TransferDirection,
                                   deviceName: String,
                                   fileName: String,
                                   fileIndex: Int,
                                   totalFiles: Int) {
        let title = direction == .push
            ? String(format: TransferCardText.pushRunningFormat, deviceName)
            : String(format: TransferCardText.pullRunningFormat, deviceName)
        let card = TransferCardState(
            id: TransferCardID(),
            taskID: taskID,
            phase: .running,
            title: title,
            subtitle: fileSubtitle(fileName: fileName, fileIndex: fileIndex, totalFiles: totalFiles),
            progress: TransferProgressSnapshot(fileIndex: fileIndex, totalFiles: totalFiles,
                                               fileName: fileName, percent: nil))
        transferCards.append(card)
    }

    /// 拒绝/提示类卡片：直接以终态入列，无 running 阶段，卡片 ID 独立生成。
    private func insertNoticeCard(text: String,
                                  phase: DeviceListViewModel.ToastPhase,
                                  duration: TimeInterval) {
        let card = TransferCardState(id: TransferCardID(), taskID: nil, phase: phase,
                                     title: text, subtitle: "", progress: nil)
        transferCards.append(card)
        scheduleRemoval(cardID: card.id, after: duration)
    }

    private func scheduleRemoval(cardID: TransferCardID, after duration: TimeInterval) {
        cancelTimer(for: cardID)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 存在性校验：防与点击关闭竞争（幂等双保险，design 2.4.8）
            guard self.transferCards.contains(where: { $0.id == cardID }) else { return }
            self.transferCards.removeAll { $0.id == cardID }
            self.cardTimers.removeValue(forKey: cardID)
        }
        cardTimers[cardID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func cancelTimer(for cardID: TransferCardID) {
        cardTimers[cardID]?.cancel()
        cardTimers.removeValue(forKey: cardID)
    }

    // MARK: - 私有工具

    /// 设备显示名（兜底 key，对齐 DeviceListViewModel.displayName(of:)）
    private func displayName(of key: String) -> String {
        return service.snapshot().rows.first(where: { $0.key == key })?.name ?? key
    }

    /// 卡片副标题：批量任务「第 i/N 个 · 文件名」，单文件仅文件名（D12）
    private func fileSubtitle(fileName: String, fileIndex: Int, totalFiles: Int) -> String {
        guard totalFiles > 1 else { return fileName }
        return String(format: TransferCardText.batchProgressFormat, fileIndex, totalFiles)
            + " · " + fileName
    }

    /// 受理拒绝分支 → 中文提示文案（design 2.2.2 异常映射表）
    private func warnText(for result: TransferStartResult) -> String {
        switch result {
        case .rejectedOffline:      return TransferCardText.rejectedOffline
        case .rejectedDeviceBusy:   return TransferCardText.rejectedDeviceBusy
        case .rejectedGlobalLimit:  return TransferCardText.rejectedGlobalLimit
        case .failedAdbMissing:     return TransferCardText.adbUnavailable
        default:                    return ""
        }
    }
}
