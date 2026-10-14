// ScrcpyPicker.swift - Native macOS app shell for the scrcpy picker (SwiftUI).
// Compiles to a standalone binary placed in ScrcpyPicker.app/Contents/MacOS/.
//
// AppDelegate assembles the in-process stack (no HTTP, no WebView): Toolchain
// -> DeviceService -> DeviceListViewModel + NavBarViewModel (both share the
// same service instance), hosts DeviceListScreen in an NSHostingView, drives
// the NavBar visibility poll (NSWorkspace, 2s + immediate first check), and
// forwards window occlusion changes to the service refresh loop.
//
// Build:  swiftc -o ScrcpyPicker main.swift ScrcpyPicker.swift NavBar.swift \
//                Sources/*.swift Sources/ViewModels/*.swift Sources/Views/*.swift \
//                -framework Cocoa
import Cocoa
import SwiftUI

// MARK: - App Delegate

/// @MainActor: AppKit drives every delegate callback on the main thread and
/// the assembled ViewModels are @MainActor-isolated; the explicit annotation
/// lets the Timer closure inherit main-actor isolation as well (design 2.1.3
/// thread model: UI state is only touched on the main thread).
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var service: DeviceService!
    var listViewModel: DeviceListViewModel!
    var navViewModel: NavBarViewModel!
    var transferManager: TransferManager!
    var transferViewModel: TransferViewModel!
    var navPanel: NavBarPanel?
    var navPollTimer: Timer?

    /// nonisolated: main.swift top-level code is not MainActor-isolated under
    /// the default Swift 5 language mode, so the delegate must be creatable
    /// before app.run() pumps the main thread. All stored properties are
    /// optionals (auto-nil) — no main-actor state is touched here.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 装配失败（resourcePath 缺失）时 terminate 已请求且异步生效：
        // 直接返回，不再触碰未装配的 IUO 属性（M9 失败路径防崩溃）。
        guard startServices() else { return }
        createWindow()
        listViewModel.start()
        service.startRefreshLoop()
        setupNavBarPanel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRefreshAndPolling()
    }

    // MARK: - Service + ViewModel assembly (design 2.7.2)

    /// Assembly chain: Toolchain -> DeviceService -> DeviceListViewModel +
    /// NavBarViewModel (shared service instance so the NavBar "first online
    /// device" matches the main list) -> attach banner slot. Keeps the legacy
    /// SCRCPY_TOOL_DIR export and the adb-missing stderr warning (design 1.2.4).
    /// Returns false (after requesting termination) when the bundle is broken.
    private func startServices() -> Bool {
        guard let resPath = Bundle.main.resourcePath else {
            FileHandle.standardError.write(Data("fatal: bundle resource path not found\n".utf8))
            NSApp.terminate(nil)
            return false
        }
        setenv("SCRCPY_TOOL_DIR", "\(resPath)/tools", 1)
        let tools = Toolchain.resolve(resourcesPath: resPath)
        if !tools.adbResolved {
            FileHandle.standardError.write(Data(
                "warning: adb not found at \(tools.adbPath); device list will be empty\n".utf8))
        }
        service = DeviceService(tools: tools)
        listViewModel = DeviceListViewModel(service: service)
        navViewModel = NavBarViewModel(service: service)
        navViewModel.attach(listViewModel)
        // 传输模块共享既有实例：tools / discovery 与 DeviceService 同源
        // （快照同源、工具同源，design 1.2.4 第 3 点）
        transferManager = TransferManager(service: service, tools: service.tools,
                                          discovery: service.discovery)
        transferViewModel = TransferViewModel(service: service, manager: transferManager)
        transferViewModel.start()
        return true
    }

    // MARK: - Main window (SwiftUI content)

    private func createWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scrcpy 设备选择器"
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ScrcpyPickerMain")
        window.minSize = NSSize(width: 640, height: 400)

        window.contentView = NSHostingView(
            rootView: DeviceListScreen()
                .environmentObject(listViewModel)
                .environmentObject(transferViewModel))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopRefreshAndPolling()
    }

    /// Window invisible (minimized / occluded) -> pause the service refresh
    /// loop; visible again -> resume with an immediate round (spec 5.2 rule 2,
    /// pause is enforced inside the service layer, not only in the UI).
    func windowDidMiniaturize(_ notification: Notification) {
        service.setRefreshPaused(true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        service.setRefreshPaused(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window.occlusionState.contains(.visible)
        service.setRefreshPaused(!visible)
    }

    // MARK: - NavBar visibility poll (spec 5.9 rule 3)

    private func setupNavBarPanel() {
        guard navPanel == nil else { return }
        navPanel = NavBarPanel(viewModel: navViewModel)
        // Poll every 2s: any live scrcpy process -> isVisible = true, else false.
        // The timer runs on the main run loop; assumeIsolated asserts that for
        // the compiler (the @Sendable block does not inherit actor isolation).
        navPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateNavBarVisibility()
            }
        }
        // Immediate first check.
        updateNavBarVisibility()
    }

    private func updateNavBarVisibility() {
        navViewModel.isVisible = isScrcpyRunning()
    }

    /// Detect any running scrcpy process. scrcpy is a bare Mach-O binary
    /// launched by the service; when it opens an SDL window macOS lists it
    /// as a regular application.
    ///
    /// Self-exclusion + exact executable match (spec 5.9 rule 3): this app's
    /// own bundle/executable name contains "scrcpy" (ScrcpyPicker), so a
    /// substring test over runningApplications would always match ourselves
    /// and pin the NavBar visible. Skip our own PID and compare the
    /// executable file name exactly, so unrelated apps whose names merely
    /// contain "scrcpy" cannot trigger the bar either.
    private func isScrcpyRunning() -> Bool {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            if app.processIdentifier == ownPid { continue }
            if app.executableURL?.lastPathComponent == "scrcpy" { return true }
        }
        return false
    }

    // MARK: - Teardown

    /// Stop the refresh thread and the NavBar poll. Called from both
    /// windowWillClose and applicationWillTerminate; idempotent.
    private func stopRefreshAndPolling() {
        navPollTimer?.invalidate()
        navPollTimer = nil
        service?.stopRefreshLoop()
        // 关窗即退出：终止全部进行中的 adb 传输进程，不留孤儿（FT-ERR-10 / AC-19）
        transferManager?.cancelAll()
    }
}

// End of AppDelegate. The NSApplication bootstrap lives in main.swift so that
// multi-file compilation with swiftc succeeds (top-level statements are only
// allowed in a file named main.swift).
