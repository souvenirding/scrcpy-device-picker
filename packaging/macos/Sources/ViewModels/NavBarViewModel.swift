// NavBarViewModel.swift - NavBar ViewModel（design 2.4.2 / 2.6.4，spec 5.9）
//
// 显隐状态可观察（isVisible 由 AppDelegate 的 NSWorkspace 轮询写入，2s + 首查）；
// 按键目标为快照第一台在线设备，无在线静默；banner 反馈走主窗口
// DeviceListViewModel 槽位（共享 BannerText 常量，design 2.4.2 说明 1）。
// 与 DeviceListViewModel 共享同一 DeviceServiceProtocol 实例（快照同源，
// "第一台在线设备"与主列表一致；实际装配在 T13）。
import Foundation

@MainActor
final class NavBarViewModel: ObservableObject {

    // MARK: 可观察状态（design 2.4.2）

    /// NavBar 显隐（spec 6.1 规则 2；写入方为 AppDelegate，NavBarPanel 观察变化执行显隐）
    @Published var isVisible = false

    private let service: DeviceServiceProtocol
    /// 主窗口 ViewModel 弱引用：按键 banner 反馈走主窗口槽位（design 2.4.2 说明 1）
    private weak var listViewModel: DeviceListViewModel?
    /// 按键串行队列（design 2.6.4：后台队列执行服务调用；NavBar 只发按键不发投屏，
    /// 与主窗口 picker-cast 各自串行，服务层 NSLock 保证线程安全）
    private let keyQueue = DispatchQueue(label: "picker-navkey")

    init(service: DeviceServiceProtocol) {
        self.service = service
    }

    // MARK: 装配注入点（T13 实际装配）

    /// 注入主窗口 ViewModel（banner 槽位共享；weak 避免保留环）。
    func attach(_ listViewModel: DeviceListViewModel) {
        self.listViewModel = listViewModel
    }

    // MARK: 按键命令（spec 5.9 规则 5/6，design 2.6.4）

    /// NavBar 按键：目标为第一台在线设备（快照首个 online 行，按 Key 现算）；
    /// 无在线设备静默返回（spec 5.9.3 场景 1）；进程内直调，无 URLSession/HTTP（规则 7）。
    func sendKey(code: Int) {
        guard let first = service.snapshot().rows.first(where: { $0.online }) else { return }
        let key = first.key
        // nonisolated(unsafe)：服务层内部 NSLock 线程安全（design 2.2.2 B），
        // 协议本体冻结无法标注 Sendable，由调用方担保跨队列捕获安全
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
            listViewModel?.hideBanner()   // 成功静默：清 banner（spec 5.5 规则 4）
        case .blocked:
            // 注入被拒：与 5.5.3 场景 1 相同的小米/MIUI/HyperOS 指引（spec 5.9 规则 6）
            listViewModel?.showBanner(DeviceListViewModel.BannerText.injectBlocked)
        case .failure(let error):
            listViewModel?.showBanner(DeviceListViewModel.BannerText.keyFailed(error.displayReason))
        }
    }
}