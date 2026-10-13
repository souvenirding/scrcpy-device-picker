// BannerView.swift - 顶部持续横幅（design 2.5.1 职责表，spec 5.10 规则 1/4/5）
//
// 原生样式：系统材质背景 + warning 色调；文本多行折行（排错指引文案较长，
// 不得截断改写）；text 为 nil 时不渲染不占位，避免列表跳动（design 2.5.1）。
// 内容与显隐时序由 DeviceListViewModel 驱动（单槽位新替旧，spec 5.10 规则 1）。
import SwiftUI

struct BannerView: View {

    /// 横幅文案；nil = 无横幅（不渲染、不占位）
    let text: String?

    var body: some View {
        if let text {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.callout)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)   // 多行折行
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}