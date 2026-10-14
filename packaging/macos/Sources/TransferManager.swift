// TransferManager.swift - 传输受理判定与任务执行（design 2.2.2 接口组 1/3、2.4.1~2.4.7）
//
// 架构红线（NFR-8）：传输能力以平级新模块接入，不侵入既有 Discovery / CastManager /
// DeviceService 逻辑。对外仅两条只读查询边：
//   * DeviceServiceProtocol.snapshot()（锁内深拷贝，行查找）
//   * Discovery.liveTransports()（无状态子进程查询，传输名现算）
// DeviceServiceProtocol 已冻结，不向其增删任何方法（design 1.2.4）。
//
// 关键决策：
//   * D-CONC 受理判定在单个 NSLock 临界区内原子完成「判定 + 登记」，拒绝式返回，不排队。
//   * D-TARGET 严格 live-only 现算：不复用 Discovery.resolveTarget（其无 live 候选时
//     退回 cands[0] 的语义是为投屏设计的，会导致 FT-ERR-7 提示错位，design 1.2.2）。
//   * D-PROC 终态由进程退出事件驱动（waitUntilExit），不设传输超时与看门狗。
import Foundation

// MARK: - 服务协议（design 2.2.2 接口组 1；一经实现即冻结，对齐 DeviceServiceProtocol 先例）

/// 传输服务契约。startPush / startPull 同步返回（临界区为纯内存判定，微秒级），
/// 调用方为 @MainActor 的 TransferViewModel；onProgress / onFinal 由服务层保证
/// 经主队列回调（对齐 DeviceService.onRefreshCompleted 契约，design 2.6）。
protocol TransferServiceProtocol: AnyObject {
    /// 受理推送：锁内五重判定 + 登记 + 派发任务队列
    func startPush(key: String, urls: [URL]) -> TransferStartResult
    /// 受理快捷目录拉取：同推送
    func startPull(key: String, directory: QuickPullDirectory) -> TransferStartResult
    /// 取消单个进行中任务（D-CANCEL）：终止 adb 进程 → 发 .cancelled 终态。
    /// 对已终态/未知 taskID 调用无副作用（幂等）
    func cancel(taskID: TransferTaskID)
    /// 进度回调（主线程）
    var onProgress: ((TransferProgressUpdate) -> Void)? { get set }
    /// 终态回调（主线程）
    var onFinal: ((TransferFinalUpdate) -> Void)? { get set }
    /// app 退出：终止全部进行中 adb 进程（幂等）
    func cancelAll()
}

// MARK: - 实现

final class TransferManager: TransferServiceProtocol {

    /// 组合持有既有模块（design 1.2.4 第 1 点）：只读调用，不写任何内部状态。
    private let service: DeviceServiceProtocol
    private let tools: Toolchain
    private let discovery: Discovery

    private let lock = NSLock()
    /// 活动表：deviceKey → 任务记录（每设备互斥 + 全局上限共用同一张表，design 2.4.3）
    private var activeTasks: [String: ActiveTaskRecord] = [:]
    /// 进行中进程登记表：taskID.rawValue → Process（cancelAll 与失败清理用，design 2.4.4）
    private var runningProcesses: [String: Process] = [:]

    private var _onProgress: ((TransferProgressUpdate) -> Void)?
    private var _onFinal: ((TransferFinalUpdate) -> Void)?

    init(service: DeviceServiceProtocol, tools: Toolchain, discovery: Discovery) {
        self.service = service
        self.tools = tools
        self.discovery = discovery
    }

    // MARK: - 回调槽位（锁保护，对齐 DeviceService.onRefreshCompleted）

    var onProgress: ((TransferProgressUpdate) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onProgress }
        set { lock.lock(); _onProgress = newValue; lock.unlock() }
    }

    var onFinal: ((TransferFinalUpdate) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFinal }
        set { lock.lock(); _onFinal = newValue; lock.unlock() }
    }

    // MARK: - 受理入口（design 2.4.3 五重判定）

    func startPush(key: String, urls: [URL]) -> TransferStartResult {
        let result = accept(deviceKey: key, direction: .push)
        guard case .started(let taskID) = result else { return result }
        dispatch(taskID: taskID) { [weak self] in
            self?.runPushTask(taskID: taskID, deviceKey: key, urls: urls)
        }
        return result
    }

    func startPull(key: String, directory: QuickPullDirectory) -> TransferStartResult {
        let result = accept(deviceKey: key, direction: .pull)
        guard case .started(let taskID) = result else { return result }
        dispatch(taskID: taskID) { [weak self] in
            self?.runPullTask(taskID: taskID, deviceKey: key, directory: directory)
        }
        return result
    }

    /// 受理临界区：判定与登记在同一锁内原子完成（design 2.4.3）。
    /// 顺序：adb 可用 → 行在线 → 每设备互斥 → 全局上限 → 登记。
    private func accept(deviceKey: String, direction: TransferDirection) -> TransferStartResult {
        lock.lock()
        defer { lock.unlock() }
        guard tools.adbResolved else { return .failedAdbMissing }          // FT-ERR-6
        let row = service.snapshot().rows.first(where: { $0.key == deviceKey && !$0.offline })
        guard row != nil else { return .rejectedOffline }                  // FT-DRAG-4 服务端防线
        guard activeTasks[deviceKey] == nil else { return .rejectedDeviceBusy }   // FT-COMMON-5
        guard activeTasks.count < TransferConstants.maxConcurrentTransfers
            else { return .rejectedGlobalLimit }                           // FT-COMMON-5
        let record = ActiveTaskRecord(taskID: TransferTaskID(),
                                      deviceKey: deviceKey,
                                      direction: direction,
                                      startedAt: Date(),
                                      reservedDestinationName: nil)
        activeTasks[deviceKey] = record
        return .started(taskID: record.taskID)
    }

    /// 每任务独立后台串行队列（D-CONC：3 并发上限 = 3 个队列真并行）
    private func dispatch(taskID: TransferTaskID, body: @escaping () -> Void) {
        let label = TransferConstants.transferQueueLabelPrefix + taskID.rawValue
        DispatchQueue(label: label, qos: .utility).async(execute: body)
    }

    // MARK: - 传输名严格现算（D-TARGET / FT-COMMON-1）

    /// 按 [preferred, usbSerial, tls, tcp5555] 去重构造候选序（与 resolveTarget 同一优先级序），
    /// 与 liveTransports() 实时输出匹配，返回首个 state == "device" 的候选。
    /// 无 live 候选返回 nil —— 绝不退回 cands[0]，绝不使用 UI 层缓存地址/串号/Key 直传。
    private func liveTransport(for deviceKey: String) -> String? {
        guard let row = service.snapshot().rows.first(where: { $0.key == deviceKey }) else { return nil }
        var candidates: [String] = []
        for c in [row.preferred, row.usbSerial, row.tls, row.tcp5555]
        where !c.isEmpty && !candidates.contains(c) {
            candidates.append(c)
        }
        guard !candidates.isEmpty else { return nil }
        let live = discovery.liveTransports()
        for c in candidates where live[c] == "device" { return c }
        return nil
    }

    // MARK: - 回调发布（design 2.6：一律经主队列）

    private func publishProgress(_ update: TransferProgressUpdate) {
        lock.lock()
        let callback = _onProgress
        lock.unlock()
        DispatchQueue.main.async { callback?(update) }
    }

    /// 终态发布 + 槽位释放：移除活动表与进程登记（该设备立即释放、全局槽位立即让出）
    private func publishFinal(_ update: TransferFinalUpdate) {
        lock.lock()
        activeTasks.removeValue(forKey: update.deviceKey)
        runningProcesses.removeValue(forKey: update.taskID.rawValue)
        let callback = _onFinal
        lock.unlock()
        DispatchQueue.main.async { callback?(update) }
    }

    // MARK: - 进程登记与终止（FT-ERR-8 / FT-ERR-10）

    private func register(process: Process, taskID: TransferTaskID) {
        lock.lock()
        runningProcesses[taskID.rawValue] = process
        lock.unlock()
    }

    private func unregister(taskID: TransferTaskID) {
        lock.lock()
        runningProcesses.removeValue(forKey: taskID.rawValue)
        lock.unlock()
    }

    func cancel(taskID: TransferTaskID) {
        lock.lock()
        // ① 标记：执行器在进程退出后据此发 .cancelled（而非 failed），
        //    并据此清理拉取半包残留（D-CANCEL / D-CLEANUP）
        if var record = activeTasks.first(where: { $0.value.taskID.rawValue == taskID.rawValue })?.value {
            if record.isCancelled { lock.unlock(); return }   // 幂等：重复取消无副作用
            record.isCancelled = true
            activeTasks[record.deviceKey] = record
        }
        let process = runningProcesses[taskID.rawValue]
        lock.unlock()
        // ② 终止进程：waitUntilExit 随即返回，执行器推进到终态发布
        if let process, process.isRunning { process.terminate() }
    }

    func cancelAll() {
        lock.lock()
        let processes = Array(runningProcesses.values)
        lock.unlock()
        // 已退出的进程调用 terminate() 无害，本方法幂等（design 2.4.4）
        for p in processes where p.isRunning { p.terminate() }
    }

    /// 该任务是否已被用户取消（执行器循环内轮询，取消后停止推进剩余文件）
    private func isCancelled(taskID: TransferTaskID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeTasks.values.contains {
            $0.taskID.rawValue == taskID.rawValue && $0.isCancelled
        }
    }

    /// 活动表已登记的落地名集合（并发拉取同名目录的防御，design 2.4.1）
    private func reservedDestinationNames() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var names: Set<String> = []
        for record in activeTasks.values {
            if let name = record.reservedDestinationName { names.insert(name) }
        }
        return names
    }

    // MARK: - 推送链（design 2.1.3.2 活动图）

    private func runPushTask(taskID: TransferTaskID, deviceKey: String, urls: [URL]) {
        // ① 严格现算（受理乐观、现算严格，FT-ERR-7）
        guard let transport = liveTransport(for: deviceKey) else {
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                             direction: .push,
                                             outcome: .failed(reason: .deviceUnreachable)))
            return
        }
        // ② mkdir -p：每任务一次（非每文件）—— 既是 FT-COMMON-3 的目录保障，
        //    也是文件夹 push 落地为 <目标>/<文件夹名>/… 的前提（design 2.4.1）
        let mkdir = runCommand(tools.adbPath,
                               ["-s", transport, "shell", "mkdir", "-p",
                                TransferConstants.devicePushDirectory])
        guard mkdir.status == 0 else {
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                             direction: .push,
                                             outcome: .failed(reason: .unknown(summary: mkdir.text.lineOne))))
            return
        }
        // ③ 逐文件推送（批量 N = 顶层投放项数，文件与文件夹各计 1）
        let totalFiles = urls.count
        let probeQueue = DispatchQueue(
            label: TransferConstants.probeQueueLabelPrefix + taskID.rawValue, qos: .utility)
        var successCount = 0
        var failureCount = 0
        var firstFailure: TransferFailureReason?
        for (offset, url) in urls.enumerated() {
            // 取消后剩余文件不再推送（D-CANCEL）
            if isCancelled(taskID: taskID) { break }
            let index = offset + 1
            let fileName = url.lastPathComponent
            // i/N 由执行器维护，不依赖 adb 输出解析（design 2.4.2 第 6 步）
            publishProgress(TransferProgressUpdate(taskID: taskID, fileIndex: index,
                                                   totalFiles: totalFiles, fileName: fileName,
                                                   percent: nil))
            // 字节实测进度：总字节取 Mac 本地源，已传输取设备端 du 实测（D-PROGRESS）
            let devicePath = TransferConstants.devicePushDirectory + "/" + fileName
            let sizeProbe = TransferSizeProbe(
                totalBytes: LocalItemSize.bytes(of: url),
                interval: TransferConstants.pushProgressPollInterval,
                queue: probeQueue,
                measure: { [weak self] in
                    guard let self else { return 0 }
                    // 单文件走 O(1) 的 stat（高频采样不被阻塞）；
                    // 文件夹无 O(1) 手段，退化为 du 递归（D-PROGRESS）
                    return url.hasDirectoryPath
                        ? DeviceItemSize.bytes(adbPath: self.tools.adbPath,
                                               transport: transport, path: devicePath) ?? 0
                        : DeviceItemSize.fileBytes(adbPath: self.tools.adbPath,
                                                   transport: transport, path: devicePath) ?? 0
                },
                onChange: { [weak self] percent in
                    self?.publishProgress(TransferProgressUpdate(taskID: taskID,
                                                                 fileIndex: index,
                                                                 totalFiles: totalFiles,
                                                                 fileName: fileName,
                                                                 percent: percent))
                })
            sizeProbe.start()
            let result = runTransferProcess(
                taskID: taskID,
                arguments: ["-s", transport, "push", url.path, TransferConstants.devicePushTarget],
                fileIndex: index, totalFiles: totalFiles, fileName: fileName)
            sizeProbe.stop()
            if isCancelled(taskID: taskID) {
                // 清理当前项在设备端的半包残留，不留残缺文件（D-CLEANUP）
                _ = runCommand(tools.adbPath,
                               ["-s", transport, "shell", "rm", "-rf", devicePath])
                publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                                 direction: .push, outcome: .cancelled))
                return
            }
            if result.exitCode == 0 {
                successCount += 1
            } else {
                failureCount += 1
                let reason = FailureReasonMapper.map(direction: .push,
                                                     output: result.output,
                                                     exitCode: result.exitCode)
                if firstFailure == nil { firstFailure = reason }
            }
        }
        publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey, direction: .push,
                                         outcome: summarize(successCount: successCount,
                                                            failureCount: failureCount,
                                                            firstFailure: firstFailure)))
    }

    // MARK: - 拉取链（design 2.1.3.3 活动图）

    private func runPullTask(taskID: TransferTaskID, deviceKey: String, directory: QuickPullDirectory) {
        guard let transport = liveTransport(for: deviceKey) else {
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                             direction: .pull,
                                             outcome: .failed(reason: .deviceUnreachable)))
            return
        }
        // ① 预检 ls -A：判存在与判空（放在落地名计算之前，预检失败不占用名字空间）
        let probe = runCommand(tools.adbPath,
                               ["-s", transport, "shell", "ls", "-A", directory.devicePath])
        let lowerProbe = probe.text.lowercased()
        let missing = TransferConstants.failurePatterns.dirMissing.contains { lowerProbe.contains($0.lowercased()) }
        if missing {
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey, direction: .pull,
                                             outcome: .failed(reason: .directoryMissing(name: directory.displayName))))
            return
        }
        if probe.status != 0 {
            let reason = FailureReasonMapper.map(direction: .pull, output: probe.text,
                                                 exitCode: probe.status,
                                                 directoryName: directory.displayName)
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                             direction: .pull, outcome: .failed(reason: reason)))
            return
        }
        guard !probe.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 空目录不是失败：warn 呈现，不发起 pull、不创建本地目录（FT-PULL-4）
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                             direction: .pull,
                                             outcome: .failed(reason: .directoryEmpty)))
            return
        }
        // ② 落地名计算 + 锁内登记（并发拉取同名目录防御，design 2.4.1）
        let destinationName = PullDestinationComposer.firstAvailableName(
            base: directory.displayName,
            in: TransferConstants.downloadsDirectoryURL,
            excluding: reservedDestinationNames())
        lock.lock()
        if var record = activeTasks[deviceKey], record.taskID.rawValue == taskID.rawValue {
            record.reservedDestinationName = destinationName
            activeTasks[deviceKey] = record
        }
        lock.unlock()
        let destination = TransferConstants.downloadsDirectoryURL
            .appendingPathComponent(destinationName)
        // 预检期取消：尚未启动 adb 进程，直接以 cancelled 终态收束（D-CANCEL）
        if isCancelled(taskID: taskID) {
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                             direction: .pull, outcome: .cancelled))
            return
        }
        // ③ 总字节实测：设备端 du -sk（实测 0.25~1.2s），用于换算真实百分比（D-PROGRESS）
        let totalBytes = DeviceItemSize.bytes(adbPath: tools.adbPath, transport: transport,
                                              path: directory.devicePath) ?? 0
        // ④ 拉取整棵目录树
        publishProgress(TransferProgressUpdate(taskID: taskID, fileIndex: 1, totalFiles: 1,
                                               fileName: directory.displayName, percent: nil))
        let probeQueue = DispatchQueue(
            label: TransferConstants.probeQueueLabelPrefix + taskID.rawValue, qos: .utility)
        let sizeProbe = TransferSizeProbe(
            totalBytes: totalBytes,
            interval: TransferConstants.pullProgressPollInterval,
            queue: probeQueue,
            measure: { LocalItemSize.bytes(of: destination) },
            onChange: { [weak self] percent in
                self?.publishProgress(TransferProgressUpdate(taskID: taskID, fileIndex: 1,
                                                             totalFiles: 1,
                                                             fileName: directory.displayName,
                                                             percent: percent))
            })
        sizeProbe.start()
        let result = runTransferProcess(
            taskID: taskID,
            arguments: ["-s", transport, "pull", directory.devicePath, destination.path],
            fileIndex: 1, totalFiles: 1, fileName: directory.displayName)
        sizeProbe.stop()
        if isCancelled(taskID: taskID) {
            // 清理本地半包残留：落地名为本次新分配，删除不触及用户既有文件（D-CLEANUP）
            try? FileManager.default.removeItem(at: destination)
            publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                             direction: .pull, outcome: .cancelled))
            return
        }
        let outcome: TransferFinalResult
        if result.exitCode == 0 {
            outcome = .succeeded(fileCount: 1)
        } else {
            outcome = .failed(reason: FailureReasonMapper.map(direction: .pull,
                                                              output: result.output,
                                                              exitCode: result.exitCode,
                                                              directoryName: directory.displayName))
        }
        publishFinal(TransferFinalUpdate(taskID: taskID, deviceKey: deviceKey,
                                         direction: .pull, outcome: outcome))
    }

    // MARK: - 三态汇总（design 2.4.2 第 4 步）

    private func summarize(successCount: Int,
                           failureCount: Int,
                           firstFailure: TransferFailureReason?) -> TransferFinalResult {
        if failureCount == 0 { return .succeeded(fileCount: successCount) }
        if successCount > 0 {
            return .partialFailure(successCount: successCount,
                                   failureCount: failureCount,
                                   firstFailure: firstFailure ?? .unknown(summary: ""))
        }
        return .failed(reason: firstFailure ?? .unknown(summary: ""))
    }

    // MARK: - adb 传输进程（design 2.4.1 / 2.4.2）

    /// 执行一次 adb 传输命令：stderr 增量解析进度，stdout 独立管道排空防阻塞。
    /// arguments 一律独立 argv 元素，绝不拼接 shell 命令字符串 —— 中文/空格/emoji/括号
    /// 文件名原样到达 adb（FT-ERR-4 的机制保证，design 2.4.1）。
    /// 终态由 waitUntilExit 返回驱动（D-PROC：退出即返回即推进，不设超时）。
    private func runTransferProcess(taskID: TransferTaskID,
                                    arguments: [String],
                                    fileIndex: Int,
                                    totalFiles: Int,
                                    fileName: String) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tools.adbPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: tools.toolDir)

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe

        let errorHandle = errorPipe.fileHandleForReading
        let outputHandle = outputPipe.fileHandleForReading

        var buffer = Data()
        var stderrText = ""
        var lastPercent: Int?

        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF 纪律：置 nil 释放派发队列，防泄漏（design 2.4.2 第 5 步）
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            guard let text = String(data: buffer, encoding: .utf8) else { return }
            stderrText = text
            // 仅百分比数值变化时发布，重复的 \r 原地刷新被吸收（design 2.4.2 第 4 步）
            guard let percent = ProgressLineParser.parse(text), percent != lastPercent else { return }
            lastPercent = percent
            let update = TransferProgressUpdate(taskID: taskID, fileIndex: fileIndex,
                                                totalFiles: totalFiles, fileName: fileName,
                                                percent: percent)
            guard let self else { return }
            self.publishProgress(update)
        }
        outputHandle.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        do {
            try process.run()
        } catch {
            errorHandle.readabilityHandler = nil
            outputHandle.readabilityHandler = nil
            return (-1, "无法启动 adb：\(error.localizedDescription)")
        }
        register(process: process, taskID: taskID)
        process.waitUntilExit()
        // 进程已退出：清除 handler（EOF 纪律）并释放登记（FT-ERR-8 不留孤儿）
        errorHandle.readabilityHandler = nil
        outputHandle.readabilityHandler = nil
        unregister(taskID: taskID)
        // 兜底补读：handler 尚未送达的末段 stderr（进程退出前写入的错误原文），
        // 供 FailureReasonMapper 生成失败摘要（FT-NOTIF-4）
        var tail = errorHandle.availableData
        while !tail.isEmpty {
            buffer.append(tail)
            tail = errorHandle.availableData   // EOF 返回空 Data，循环自然结束
        }
        if let text = String(data: buffer, encoding: .utf8) { stderrText = text }
        return (process.terminationStatus, stderrText)
    }
}

// MARK: - 字节实测进度（D-PROGRESS）

/// 传输字节进度轮询器。
///
/// 背景（真机实测）：adb 1.0.41（Version 37.0.1）在 stderr 被 Pipe 接管（非 TTY）时
/// **不输出** `[ 42%]` 进度行，仅在传输结束时输出一行摘要。因此 design 2.4.2 的
/// 进度行解析通道在真实 adb 下永不命中，进度改由「已传输字节 / 总字节」实测换算：
///   * 推送：总字节 = Mac 本地源大小，已传输 = 设备端 `du -sk` 实测
///   * 拉取：总字节 = 设备端 `du -sk` 实测，已传输 = Mac 落地目录递归实测
/// ProgressLineParser 保留为兜底通道（TTY 场景），两条通道共用同一 percent 字段。
///
/// 轮询在调用方指定的后台队列执行；百分比数值变化时才回调，重复采样被吸收。
final class TransferSizeProbe {

    private let totalBytes: Int64
    private let measure: () -> Int64
    private let onChange: (Int) -> Void
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastPercent = -1
    private var stopped = false

    private let interval: TimeInterval

    init(totalBytes: Int64,
         interval: TimeInterval,
         queue: DispatchQueue,
         measure: @escaping () -> Int64,
         onChange: @escaping (Int) -> Void) {
        self.totalBytes = totalBytes
        self.interval = interval
        self.queue = queue
        self.measure = measure
        self.onChange = onChange
    }

    /// 总字节为 0（测量失败）时不启动，调用方保持不定进度降级态。
    func start() {
        guard totalBytes >= TransferConstants.minimumProgressTotalBytes else { return }
        lock.lock()
        if stopped { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + TransferConstants.progressPollInitialDelay,
                       repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    /// 停止并释放定时器。幂等；stop 后不可再 start（设计上每个文件/任务一个新实例）。
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func tick() {
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        guard !stopped else { return }
        let bytes = measure()
        let percent = Int(min(100, max(0, bytes * 100 / totalBytes)))
        lock.lock()
        let changed = percent != lastPercent
        if changed { lastPercent = percent }
        lock.unlock()
        guard changed else { return }
        onChange(percent)
    }
}

// MARK: - 小工具

extension String {
    /// 首个非空行（失败摘要用，对齐 FailureReasonMapper 的首行摘要先例）
    var lineOne: String {
        for line in split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

// MARK: - 纯函数（design 2.2.2 接口组 3；静态、无副作用、可独立验证）

/// adb 进度行解析：`[ 42%] /sdcard/Download/x.jpg` → 42（design 2.4.2 第 3 步）。
/// 取最后一个能匹配的非空段；末尾未完成的半行片段（如 `[ 6`）自然被跳过，
/// 交由下一次回调补全后解析（防半行误判）。全不匹配返回 nil（调用方维持原状态），永不抛错。
enum ProgressLineParser {
    static func parse(_ chunk: String) -> Int? {
        let pieces = chunk.split(omittingEmptySubsequences: false,
                                 whereSeparator: { $0 == "\r" || $0 == "\n" })
        for piece in pieces.reversed() {
            let segment = String(piece).trimmingCharacters(in: .whitespaces)
            if segment.isEmpty { continue }
            guard let groups = reGroups(TransferConstants.progressLinePattern, segment),
                  groups.count > 1,
                  let value = Int(groups[1]),
                  (0...100).contains(value) else { continue }
            return value
        }
        return nil
    }
}

/// Mac 本地文件/目录字节数（目录递归汇总）。取不到返回 0（调用方降级不定进度），永不抛错。
enum LocalItemSize {
    static func bytes(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(at: url,
                                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                     options: [],
                                                     errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// 设备端文件/目录字节数测量。
/// 实测设备端 du 不支持 `-sb`，故递归测量用 `-sk`（`du -sb` 会报"No such file or directory"）。
enum DeviceItemSize {

    /// 递归汇总（文件与目录皆可）：`du -sk`，KiB → 字节。失败返回 nil。
    /// 代价随目录规模增长，仅用于低频场景（拉取总大小、文件夹推送）。
    static func bytes(adbPath: String, transport: String, path: String) -> Int64? {
        let result = runCommand(adbPath, ["-s", transport, "shell"]
                                + TransferConstants.duArguments + [path])
        guard result.status == 0 else { return nil }
        // 输出形如 "9456691\t/sdcard/Download"
        guard let blocks = firstInteger(of: result.text) else { return nil }
        return blocks * TransferConstants.duKiloBytesPerBlock
    }

    /// 单文件大小（不递归）：`stat -c %s`，O(1)。失败返回 nil。
    /// 高频轮询专用 —— 实测对正在写入的 GB 级文件，`du -sk` 会显著阻塞轮询节拍
    /// （2GB 推送全程仅采到 1 拍），而 stat 为常数代价，可稳定按秒采样。
    /// 注意：对目录 stat 只返回目录项自身大小（实测 8192），故仅用于单文件。
    static func fileBytes(adbPath: String, transport: String, path: String) -> Int64? {
        let result = runCommand(adbPath, ["-s", transport, "shell"]
                                + TransferConstants.statSizeArguments + [path])
        guard result.status == 0 else { return nil }
        return firstInteger(of: result.text)
    }

    private static func firstInteger(of text: String) -> Int64? {
        guard let token = text.split(whereSeparator: {
                  $0 == "\t" || $0 == " " || $0 == "\n" || $0 == "\r"
              }).first else { return nil }
        return Int64(token)
    }
}

/// adb 输出 → 中文失败原因（design 2.4.7 规则表，匹配顺序自上而下首中即返）。
enum FailureReasonMapper {
    static func map(direction: TransferDirection,
                    output: String,
                    exitCode: Int32,
                    directoryName: String = "") -> TransferFailureReason {
        let haystack = output.lowercased()
        for pattern in TransferConstants.failurePatterns.disconnected
        where haystack.contains(pattern.lowercased()) {
            return .deviceDisconnected
        }
        for pattern in TransferConstants.failurePatterns.noSpace
        where haystack.contains(pattern.lowercased()) {
            // 方向感知：push 时来自设备端写入，pull 时来自 Mac 本地写入（FT-ERR-3 / FT-PULL-5）
            return direction == .push ? .deviceStorageFull : .macDiskFull
        }
        if direction == .pull {
            for pattern in TransferConstants.failurePatterns.dirMissing
            where haystack.contains(pattern.lowercased()) {
                return .directoryMissing(name: directoryName)
            }
        }
        _ = exitCode
        return .unknown(summary: firstMeaningfulLine(of: output))
    }

    /// stderr 首个非空行（对齐 CastManager.logSummary 的「首行摘要」先例）
    private static func firstMeaningfulLine(of text: String) -> String {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

/// 拉取落地名计算：`~/Downloads/<目录名>`，已存在则 `<目录名> 2`、`<目录名> 3`…
/// 同时排除活动表已登记的名字（防并发拉取同名目录的未落盘窗口，design 2.4.1）。
enum PullDestinationComposer {
    static func firstAvailableName(base: String,
                                   in directory: URL,
                                   excluding reserved: Set<String>) -> String {
        let fileManager = FileManager.default
        let separator = TransferConstants.destinationNameSeparator
        var candidate = base
        var index = 2
        while index <= TransferConstants.maxDestinationNameAttempts {
            if reserved.contains(candidate) {
                candidate = "\(base)\(separator)\(index)"
                index += 1
                continue
            }
            if !fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            candidate = "\(base)\(separator)\(index)"
            index += 1
        }
        return candidate
    }
}
