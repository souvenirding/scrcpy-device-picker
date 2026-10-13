// CastToastView.swift - 右下角一次性进度卡片（design 2.5.1，spec 5.10 规则 2/3/5）
//
// 四态视觉：running=ProgressView 转圈 / ok=绿✓ / err=红! / warn=黄!
// （SF Symbols checkmark.circle.fill / exclamationmark.circle.fill）。
// 点击卡片立即关闭（onTapGesture → dismissToast，spec 5.10 规则 2）；
// 自动消失由 ViewModel 计时器驱动（ToastDuration 常量，本视图不计时）。
// 右下角 overlay 位置由 DeviceListScreen 挂载。
import SwiftUI

struct CastToastView: View {

    let toast: DeviceListViewModel.ToastState
    @ObservedObject var viewModel: DeviceListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                phaseIcon
                Text(toast.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(toast.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .onTapGesture { viewModel.dismissToast() }   // 点击立即关闭（spec 5.10 规则 2）
    }

    // MARK: - 四态图标（spec 5.10 规则 2）

    @ViewBuilder
    private var phaseIcon: some View {
        switch toast.phase {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .err:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .warn:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.yellow)
        }
    }
}