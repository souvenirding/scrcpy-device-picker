// DeviceContextMenu.swift - 设备行右键菜单（design 2.5.2，spec 5.3/5.5/5.6/5.7/5.8，验收 F9/F4）
//
// 在线行 13 + 3 项（含三条分隔）：投屏四模式 / 按键四项 / [条件]断开无线 /
// 传输两项（推送 + 拉取子菜单）/ 备注名/复制/移除；
// 离线行 3 项：备注名/复制地址/移除（spec 9.1 F4）—— 传输项仅挂在线分支，
// row.offline 分叉天然满足 FT-PUSH-4「离线行不显示传输项」。
// 菜单文案与条件项逐项对齐原版 app.js buildMenu（spec 9.1 F9）：
// 「用 USB 投屏」仅 row.usb、「断开无线会话」仅 row.tls 非空（spec 5.7 规则 4）。
// 按键码用具名常量 KeyEventCode（杜绝魔法数字，design 2.5.2）；
// 全部命令经 DeviceListViewModel / TransferViewModel，视图无业务逻辑（spec 6.1 规则 1）。
// 新增传输项一律纯文字标签，禁止 Label(_:systemImage:)（FT-PUSH-5 / NFR-4 / AC-20）。
import SwiftUI

/// Android keyevent 键码具名常量（spec 5.5 规则 1 / 5.9 规则 1，值对齐 Android KEYCODE_*）。
/// 右键菜单按键四项与 NavBar 七键共用（NavBarView.actions 引用）。
enum KeyEventCode {
    static let back       = 4     // KEYCODE_BACK（返回）
    static let home       = 3     // KEYCODE_HOME（桌面）
    static let recents    = 187   // KEYCODE_APP_SWITCH（多任务）
    static let volumeDown = 25    // KEYCODE_VOLUME_DOWN（音量-）
    static let volumeUp   = 24    // KEYCODE_VOLUME_UP（音量+）
    static let sleep      = 223   // KEYCODE_SLEEP（息屏）
    static let wakeUp     = 224   // KEYCODE_WAKEUP（唤醒屏幕）
}

struct DeviceContextMenu: View {

    let row: DeviceRowVM
    @ObservedObject var viewModel: DeviceListViewModel
    @EnvironmentObject private var transferViewModel: TransferViewModel

    var body: some View {
        if row.offline {
            offlineItems   // 离线行仅 3 项（spec 9.1 F4）
        } else {
            onlineItems    // 在线行 13 + 传输 2 项（spec 9.1 F9）
        }
    }

    /// 尾三项：备注名 / 复制地址 / 移除（在线与离线行均提供，
    /// spec 5.6 规则 1 / 5.8 规则 1 / 5.7 规则 1）
    @ViewBuilder
    private var offlineItems: some View {
        Button("设置备注名…") { viewModel.beginAlias(key: row.key) }
        Button("复制地址") { viewModel.copyAddress(key: row.key) }
        Button("从列表移除") { viewModel.beginRemove(key: row.key) }
    }

    /// 在线行 13 项，顺序逐项对齐 spec 9.1 F9 与原版 app.js:308-323
    @ViewBuilder
    private var onlineItems: some View {
        // 投屏四模式（spec 5.3 规则 4）
        Button("投屏（自动选通道）") { viewModel.cast(key: row.key, mode: .auto) }
        if row.usb {
            Button("用 USB 投屏") { viewModel.cast(key: row.key, mode: .usb) }
        }
        Button("投屏（不同步剪贴板）") {
            viewModel.cast(key: row.key, mode: .auto, noClipboard: true)
        }
        Button("强制重新投屏（关掉旧窗口重开）") {
            viewModel.cast(key: row.key, mode: .auto, force: true)
        }
        Divider()
        // 按键四项（spec 5.5 规则 1；发给被右键的那台设备，规则 2）
        Button("唤醒屏幕") { viewModel.sendKey(key: row.key, code: KeyEventCode.wakeUp) }
        Button("返回") { viewModel.sendKey(key: row.key, code: KeyEventCode.back) }
        Button("桌面") { viewModel.sendKey(key: row.key, code: KeyEventCode.home) }
        Button("多任务") { viewModel.sendKey(key: row.key, code: KeyEventCode.recents) }
        // 断开无线会话：仅 TLS 通道设备显示（spec 5.7 规则 4）
        if !row.tls.isEmpty {
            Button("断开无线会话") { viewModel.disconnectWireless(key: row.key) }
        }
        Divider()
        // 文件传输两项（design 2.4.6）：仅在在线分支内，离线行不显示（FT-PUSH-4）
        Button("推送文件到设备…") {
            // 省略号 = 打开面板（macOS 惯例）；取消返回 nil → 静默（FT-PUSH-3）
            if let urls = FilePickPanel.pickFiles() {
                transferViewModel.pushFiles(key: row.key, urls: urls)
            }
        }
        Menu {
            // 数据源即 TransferConstants.quickPullDirectories，不增减目录项（FT-PULL-1 / D6）
            ForEach(TransferConstants.quickPullDirectories, id: \.displayName) { directory in
                Button("拉取 \(directory.displayName) 目录") {
                    transferViewModel.pullQuickDirectory(key: row.key, directory: directory)
                }
            }
        } label: {
            Text("从设备拉取文件")   // 子菜单父项不带省略号（D11）
        }
        Divider()
        offlineItems   // 尾三项与离线行一致
    }
}