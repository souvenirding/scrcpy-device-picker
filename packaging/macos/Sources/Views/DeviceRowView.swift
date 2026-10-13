// DeviceRowView.swift - 设备单行渲染（design 2.5.1 职责表 / 2.9 R9，spec 5.1）
//
// 纯渲染视图：行数据与「启动中」标志经参数注入，不含业务逻辑（spec 6.1 规则 1）；
// 双击投屏与右键菜单由 DeviceListScreen 行级修饰符挂载（design 2.5.1 视图树分工）。
// 七列布局（spec 5.1 规则 1）：设备/型号/系统/连接/地址/电量/状态；
// 各列 minWidth + layoutPriority 保证窗口缩放（min 640×400）时列宽稳定，
// 地址列允许中段截断（design 2.9 R9）。
import SwiftUI

struct DeviceRowView: View {

    let row: DeviceRowVM
    /// 该行是否处于「启动中」（castingKeys 含 key，spec 5.1 规则 6）
    let isCasting: Bool

    /// 各列最小宽度（pt，design 2.9 R9：空间不足时先截地址列，保设备/状态列）
    private enum Column {
        static let deviceWidth: CGFloat = 150
        static let modelWidth: CGFloat = 110
        static let systemWidth: CGFloat = 70
        static let connWidth: CGFloat = 110
        static let addrWidth: CGFloat = 160
        static let batteryWidth: CGFloat = 90
    }

    /// 离线行整体不透明度（spec 5.1 规则 7 置灰）
    private static let offlineOpacity = 0.45

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            deviceColumn
                .layoutPriority(1)
            textColumn(row.model, minWidth: Column.modelWidth)
            textColumn(row.android, minWidth: Column.systemWidth)
            textColumn(connText, minWidth: Column.connWidth)
            textColumn(row.addr, minWidth: Column.addrWidth, truncation: .middle)
            textColumn(batteryText, minWidth: Column.batteryWidth)
            statusColumn
                .layoutPriority(1)
        }
        .padding(.vertical, 2)
        .opacity(row.offline ? Self.offlineOpacity : 1)
        .background(isCasting ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    // MARK: - 设备列（spec 5.1 规则 2：状态圆点 + 显示名）

    private var deviceColumn: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(row.online ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minWidth: Column.deviceWidth, alignment: .leading)
    }

    // MARK: - 状态列三态（spec 5.1 规则 6：启动中 / 离线 / 在线）

    @ViewBuilder
    private var statusColumn: some View {
        if isCasting {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("启动中…")
            }
        } else if row.offline {
            Text("离线")
                .foregroundStyle(.secondary)
        } else {
            Text("在线")
        }
    }

    // MARK: - 列文本拼装

    /// 连接列：通道标签以 " + " 拼接（spec 5.1 规则 3；rawValue 即展示文案）
    private var connText: String {
        row.conn.map(\.rawValue).joined(separator: " + ")
    }

    /// 电量列：「电量百分比 + 充电状态」；无电量数据留空（spec 5.1 规则 5）
    private var batteryText: String {
        guard !row.battery.isEmpty else { return "" }
        return row.charging.isEmpty ? "\(row.battery)%" : "\(row.battery)% \(row.charging)"
    }

    /// 通用文本列：单行 + 指定截断模式 + 最小宽度左对齐
    private func textColumn(_ text: String, minWidth: CGFloat,
                            truncation: Text.TruncationMode = .tail) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(truncation)
            .frame(minWidth: minWidth, alignment: .leading)
    }
}