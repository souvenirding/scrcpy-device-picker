// DeviceListScreen.swift - 主窗口组合根（design 2.5.1 视图树，spec 5.1/5.2/5.3/5.6/5.7/5.10）
//
// VStack = BannerView（顶部横幅，非 nil 常驻）+ List（DeviceRowView×N，D4 决策：不用 Table）
// + Divider + 底部状态栏；CastToastView 右下角 overlay；toolbar 刷新/深度刷新。
// 备注名对话框：SwiftUI alert + TextField（macOS 13 正式支持，design 2.9 R6；
// 异常时回退 NSAlert+NSTextField 附件视图）；移除确认 confirmationDialog。
// ViewModel 经 @EnvironmentObject 注入（AppDelegate 装配，T13）；
// 视图无业务逻辑，全部命令经 DeviceListViewModel（spec 6.1 规则 1/2）。
import SwiftUI

struct DeviceListScreen: View {

    @EnvironmentObject private var viewModel: DeviceListViewModel

    /// 备注名输入草稿；nil = 未编辑（跟随对话框预填值，spec 5.6 规则 1）。
    /// State 值类型直用（非 @State 属性包装语法）：本机 CLT swiftc 缺
    /// SwiftUIMacros 宏插件、@State 宏无法展开；State 结构体与 nonmutating
    /// wrappedValue setter 均为 macOS 13 公开 API，语义与 @State 等价。
    /// 用「nil 跟随预填」而非 onChange 同步，规避 alert 呈现与状态写入的时序问题。
    private var aliasDraft = State<String?>(initialValue: nil)

    var body: some View {
        VStack(spacing: 0) {
            BannerView(text: viewModel.banner)
            deviceList
            Divider()
            footer
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = viewModel.toast {
                CastToastView(toast: toast, viewModel: viewModel)
                    .padding(16)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.refresh(deep: false)          // spec 5.2 规则 3
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新设备列表")
                Button {
                    viewModel.refresh(deep: true)           // spec 5.2 规则 4
                } label: {
                    Label("深度刷新", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("忽略详情缓存，强制重新探测")
            }
        }
        .alert("备注名（留空清除）：", isPresented: aliasPresented) {
            TextField("备注名", text: aliasTextBinding)
            Button("确认") {
                viewModel.confirmAlias(aliasDraft.wrappedValue
                                       ?? viewModel.aliasDialog?.initialText ?? "")
            }
            Button("取消", role: .cancel) { viewModel.cancelAlias() }
        }
        .confirmationDialog("从缓存列表移除该设备？",
                            isPresented: removePresented,
                            titleVisibility: .visible) {
            Button("移除", role: .destructive) { viewModel.confirmRemove() }
            Button("取消", role: .cancel) { viewModel.cancelRemove() }
        }
    }

    // MARK: - 设备列表（List + 行级交互）

    private var deviceList: some View {
        List {
            ForEach(viewModel.rows) { row in
                DeviceRowView(row: row, isCasting: viewModel.castingKeys.contains(row.key))
                    .contextMenu {
                        DeviceContextMenu(row: row, viewModel: viewModel)
                    }
                    .onTapGesture(count: 2) {
                        // 双击投屏：仅在线行；离线行忽略（spec 5.3 规则 1/2）
                        if !row.offline {
                            viewModel.cast(key: row.key, mode: .auto)
                        }
                    }
            }
        }
        .listStyle(.inset)
        .overlay {
            if viewModel.loading {
                ProgressView()                    // 首轮刷新未完成（spec 5.1 规则 10）
            } else if viewModel.rows.isEmpty {
                Text("未发现设备——插入 USB 设备后会自动出现在这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 底部状态栏（spec 5.1 规则 10 / 5.2 规则 5）

    private var footer: some View {
        HStack(spacing: 8) {
            if viewModel.loading {
                Text("加载中…")
            } else {
                Text("共 \(viewModel.rows.count) 台 · 上次刷新 \(viewModel.lastRefreshText)")
            }
            Spacer(minLength: 0)
            Text(viewModel.wirelessLabel)         // 恒「无线/扫描：关闭」（服务恒 false）
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
                .help("公司网络等共享环境默认关闭无线调试/子网扫描，避免误连陌生设备。需要时以 -AllowWireless 启动。")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 对话框呈现绑定（派生自 ViewModel 状态）

    /// 备注名 alert 呈现：aliasDialog 非 nil 即呈现（spec 5.6 规则 1）。
    /// 关闭回调统一走 cancelAlias（幂等：确认路径 confirmAlias 已先置 nil）；
    /// Esc 由 SwiftUI alert 天然等同取消（spec 5.6 规则 5）。
    private var aliasPresented: Binding<Bool> {
        Binding(
            get: { viewModel.aliasDialog != nil },
            set: { shown in
                if !shown {
                    viewModel.cancelAlias()   // 取消不动（spec 5.6 规则 4）
                    aliasDraft.wrappedValue = nil   // 清草稿，下次打开跟随新预填值
                }
            }
        )
    }

    /// TextField 文本：未编辑（草稿为 nil）时跟随预填值 initialText，
    /// 编辑后以草稿为准；确认取值同规则（spec 5.6 规则 1/2/3）。
    private var aliasTextBinding: Binding<String> {
        Binding(
            get: { aliasDraft.wrappedValue ?? viewModel.aliasDialog?.initialText ?? "" },
            set: { aliasDraft.wrappedValue = $0 }
        )
    }

    /// 移除确认呈现：removeConfirmKey 非 nil 即呈现（spec 5.7 规则 1）。
    private var removePresented: Binding<Bool> {
        Binding(
            get: { viewModel.removeConfirmKey != nil },
            set: { shown in
                if !shown { viewModel.cancelRemove() }   // 取消保留（spec 5.7 规则 3）
            }
        )
    }
}