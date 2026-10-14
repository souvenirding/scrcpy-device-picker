// TransferCardsView.swift - 右下角传输卡片堆叠区（design 2.4.8，FT-PROG-1~4 / FT-NOTIF-1~3）
//
// 视觉语言逐参数对齐既有 CastToastView（regularMaterial 圆角 10 + 阴影 + maxWidth 280），
// 四态图标仅复用其既有 SF Symbols 状态语言，不新增图标（NFR-4 / AC-20）。
// 卡片区为空时不渲染不占位（对齐 BannerView 的 nil 不占位纪律）。
// 排序与截断是本视图内的纯函数式计算，无业务判定；命令一律经 TransferViewModel。
import SwiftUI

struct TransferCardsView: View {

    @EnvironmentObject private var transferViewModel: TransferViewModel

    var body: some View {
        Group {
            if !transferViewModel.transferCards.isEmpty {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(visibleCards) { card in
                        TransferCardRow(card: card)
                            .onTapGesture {
                                // 进行中卡片不响应点击关闭：避免误关导致进度不可见，
                                // 且关闭卡片不会停止传输（D-CANCEL）
                                if card.phase != .running {
                                    transferViewModel.dismissCard(id: card.id)
                                }
                            }
                    }
                    if overflowCount > 0 {
                        Text(String(format: TransferCardText.overflowSummaryFormat, overflowCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 排序与截断（FT-PROG-3：running 优先，同相位按入列序，最多 3 张）

    /// 稳定排序：先按相位权重（进行中优先），权重相同按入列顺序（enumerated 下标）。
    private var orderedCards: [TransferCardState] {
        transferCards.enumerated().sorted { a, b in
            let ra = CardPhaseRank.of(a.element.phase)
            let rb = CardPhaseRank.of(b.element.phase)
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    private var visibleCards: [TransferCardState] {
        Array(orderedCards.prefix(TransferConstants.maxVisibleCards))
    }

    private var transferCards: [TransferCardState] {
        transferViewModel.transferCards
    }

    private var overflowCount: Int {
        orderedCards.count - visibleCards.count
    }
}

/// 相位排序权重：进行中置顶（用户最关心），其余终态按入列时间升序（design 2.4.8）
private enum CardPhaseRank {
    static func of(_ phase: DeviceListViewModel.ToastPhase) -> Int {
        switch phase {
        case .running: return 0
        case .ok, .warn, .err: return 1
        }
    }
}

// MARK: - 单卡片

private struct TransferCardRow: View {

    let card: TransferCardState
    @EnvironmentObject private var transferViewModel: TransferViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                phaseIcon
                Text(card.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                // 仅进行中卡片承载取消按钮（D-CANCEL；终态卡片点击空白处关闭）
                if card.phase == .running {
                    Spacer(minLength: 4)
                    Button(TransferCardText.cancelButton) {
                        transferViewModel.cancelTransfer(cardID: card.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            if !card.subtitle.isEmpty {
                Text(card.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let progress = card.progress {
                progressArea(progress)
            }
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    /// 四态图标：复用 CastToastView 既有视觉语言（非新增图标）
    @ViewBuilder
    private var phaseIcon: some View {
        switch card.phase {
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

    /// 进度区：确定态走进度条 + 百分比，降级态（percent == nil）转圈 + 「传输中…」（FT-PROG-4）
    @ViewBuilder
    private func progressArea(_ progress: TransferProgressSnapshot) -> some View {
        if let percent = progress.percent {
            HStack(spacing: 8) {
                ProgressView(value: Double(percent), total: 100)
                Text("\(percent)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(TransferCardText.indeterminateProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
