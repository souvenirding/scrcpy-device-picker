// FilePickPanel.swift - 推送文件选择面板（design 2.4.6，FT-PUSH-1/3，D10）
//
// 纯输入收集、无业务逻辑：只负责呈现 NSOpenPanel 并返回用户选取结果
// （对齐「输入收集在视图、命令在 ViewModel」的既有分工）。
// runModal 的模态会话是 FT-COMMON-6「除文件选择面板本身外不得弹模态」的唯一豁免。
import AppKit
import Foundation

enum FilePickPanel {

    /// 呈现多选文件/文件夹选择面板。
    /// - Returns: 用户确认且非空 → URL 列表；取消 / Esc / 空选取 → nil（调用方静默，不提示、不发起传输）。
    @MainActor
    static func pickFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true        // Cmd/Shift 多选（FT-PUSH-1）
        panel.canChooseFiles = true
        panel.canChooseDirectories = true           // 文件与文件夹混选（D10）
        panel.message = "选择要推送到设备的文件或文件夹"
        panel.prompt = "选取"
        panel.directoryURL = TransferConstants.downloadsDirectoryURL   // 默认起始「下载」
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }
}
