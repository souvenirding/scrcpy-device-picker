// NavBarView.swift - 投屏导航条 SwiftUI 内容（design 2.5.3，spec 5.9 规则 1）
//
// 7 键纯文字按钮（不使用图标——2026-10-12 用户定夺，消除图标与标签重叠隐患）；
// 键码+标签具名常量表逐项对齐 spec 5.9 规则 1 与现版布局常量
// （btnW=62/btnH=36/gap=8/pad=12），标签 12pt。
// 按键命令经 NavBarViewModel（目标=第一台在线设备，spec 5.9 规则 5；
// 无在线静默，5.9.3 场景 1）；承载壳（NSPanel 特性）在 NavBar.swift，
// 内容与壳分离（spec 6.1 规则 5）。
import SwiftUI

struct NavBarView: View {

    @ObservedObject var viewModel: NavBarViewModel

    /// 键定义常量表 (code, label)：顺序/键码/标签逐项对齐 spec 5.9 规则 1
    /// 与现版 NavBar.actions；键码引用 KeyEventCode 具名常量（杜绝魔法数字）。
    static let actions: [(code: Int, label: String)] = [
        (KeyEventCode.back,       "返回"),
        (KeyEventCode.home,       "桌面"),
        (KeyEventCode.recents,    "多任务"),
        (KeyEventCode.volumeDown, "音量-"),
        (KeyEventCode.volumeUp,   "音量+"),
        (KeyEventCode.sleep,      "息屏"),
        (KeyEventCode.wakeUp,     "唤醒"),
    ]

    /// 布局常量（与 NavBar.swift 壳侧 contentRect 同参数，面板 ≈506×60pt）
    static let buttonWidth: CGFloat = 62     // ≥62pt（spec 5.9 规则 1）
    static let buttonHeight: CGFloat = 36    // ≥36pt
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Self.actions, id: \.code) { action in
                Button {
                    viewModel.sendKey(code: action.code)
                } label: {
                    Text(action.label)
                        .font(.system(size: 12))               // 12pt 标签
                        .frame(width: Self.buttonWidth,
                               height: Self.buttonHeight)     // 62×36pt
                }
                .buttonStyle(.bordered)   // 原生按钮样式
            }
        }
        .padding(Self.padding)
    }
}