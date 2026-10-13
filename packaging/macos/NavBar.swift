// NavBar.swift - Floating always-on-top toolbar panel for the scrcpy picker (macOS).
// Shows when any scrcpy session is running; hides otherwise. Buttons send
// adb keyevent codes to the first online device through the shared
// NavBarViewModel injected by AppDelegate. Each button shows a Chinese text
// label only — icons removed per user request (the symbol above the label
// used to overlap).
//
// Shell only: panel traits / show-hide / position memory stay in this file
// (AppKit); button content is SwiftUI (NavBarView inside NSHostingView) —
// content and shell separated per spec 6.1 rule 5. Key presses go through
// the in-process service via NavBarViewModel (spec 5.9 rule 7).
//
// Chose "fixed floating panel" over "AX-attached follow bar" to avoid the
// macOS Accessibility permission prompt while keeping the buttons reachable
// from any window position. Users can drag it wherever they like.
import Cocoa
import Combine
import SwiftUI

final class NavBarPanel: NSPanel {

    private let viewModel: NavBarViewModel
    private var visibilityCancellable: AnyCancellable?

    /// 是否已完成首次定位（默认主屏底部居中）。布局常量（按钮尺寸/间距/内边距）
    /// 单一来源在 NavBarView（M7），壳侧 contentRect 按同一组常量计算，≈506×60pt。
    private var hasPositionedOnce = false

    /// Shared view model injected by AppDelegate: same DeviceService instance
    /// as the main window list, so the "first online device" target stays
    /// consistent with what the main window shows (design 2.4.2 note 1).
    init(viewModel: NavBarViewModel) {
        self.viewModel = viewModel

        let count = NavBarView.actions.count
        let totalW = NavBarView.padding * 2
            + NavBarView.buttonWidth * CGFloat(count)
            + NavBarView.spacing * CGFloat(count - 1)
        let totalH = NavBarView.padding * 2 + NavBarView.buttonHeight
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: totalW, height: totalH),
            styleMask: [.titled, .closable, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "投屏导航"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        hasShadow = true

        contentView = NSHostingView(rootView: NavBarView(viewModel: viewModel))

        // isVisible drives show/hide (spec 5.9 rule 3). [weak self] breaks the
        // panel → cancellable → closure → panel retain cycle (design 2.9 R3).
        visibilityCancellable = viewModel.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible {
                    self?.showAtDefaultPosition()
                } else {
                    self?.hide()
                }
            }
    }

    // MARK: - Show / hide

    /// Show at bottom-center of the main screen on first appearance; after
    /// that the panel keeps its frame across orderOut/orderFront cycles, so
    /// the user's dragged position is remembered for free (M8: no manual
    /// origin bookkeeping — the old lastKnownFrameOrigin write in hide()
    /// was dead code, the stored value was never read back).
    func showAtDefaultPosition() {
        if !hasPositionedOnce {
            if let screen = NSScreen.main {
                let f = frame
                let x = screen.frame.minX + (screen.frame.width - f.width) / 2
                let y = screen.frame.minY + 60
                setFrameOrigin(NSPoint(x: x, y: y))
                hasPositionedOnce = true
            }
        }
        if !isVisible { orderFrontRegardless() }
    }

    /// Hide without touching the frame: NSPanel keeps its origin while
    /// ordered out, so the next show restores the user's chosen position.
    func hide() {
        if isVisible {
            orderOut(nil)
        }
    }
}
