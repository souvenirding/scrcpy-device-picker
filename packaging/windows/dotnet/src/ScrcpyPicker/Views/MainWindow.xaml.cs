using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using ScrcpyPicker.Models;
using ScrcpyPicker.ViewModels;

namespace ScrcpyPicker.Views;

/// <summary>
/// 主窗口（View）。
///
/// 这里只放"必须由界面来做的事"：命中测试（哪一行被双击/右键）、把右键菜单按行状态搭出来、
/// 弹输入框和确认框。所有业务判断仍在 MainViewModel → PickerBackend，
/// code-behind 不碰 adb，也不自己判断能不能投屏。
/// </summary>
public partial class MainWindow
{
    public MainWindow()
    {
        InitializeComponent();
        // WPF 的 DataContext 只有事件、没有可重写的 OnDataContextChanged，
        // 而 App 是在 Show 之前才挂 VM，所以订阅必须挂在这个事件上。
        DataContextChanged += (_, _) => Subscribe(Vm);
    }

    private MainViewModel? Vm => DataContext as MainViewModel;

    private MainViewModel? _subscribed;

    /// <summary>换 VM 时先解掉旧订阅，避免同一个动作被处理两遍（正常只发生一次，但成本是零）。</summary>
    private void Subscribe(MainViewModel? next)
    {
        if (_subscribed is not null)
        {
            _subscribed.AliasRequested -= OnAliasRequested;
            _subscribed.ForgetRequested -= OnForgetRequested;
            _subscribed = null;
        }

        if (next is null) return;
        next.AliasRequested += OnAliasRequested;
        next.ForgetRequested += OnForgetRequested;
        _subscribed = next;
    }

    private void OnAliasRequested(DeviceItem item)
    {
        if (!InputDialog.TryShow(this, "设置备注名", "备注名（留空清除）：", item.Name, out string alias))
            return;
        _ = Vm?.SetAlias(item.Key, alias);
    }

    private void OnForgetRequested(DeviceItem item)
    {
        var answer = MessageBox.Show(this, "从缓存列表移除该设备？", "确认",
            MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (answer == MessageBoxResult.Yes) _ = Vm?.Forget(item.Key);
    }

    // ---- 表格交互 ----

    /// <summary>双击行 = 用自动通道投屏（离线行不响应，和旧前端一致）。</summary>
    private void Grid_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        var item = ItemAt(e.OriginalSource as DependencyObject);
        if (item is null || item.IsOffline) return;
        dgDevices.SelectedItem = item;
        Vm?.CastCommand.Execute(item);
    }

    /// <summary>
    /// 右键菜单：整份照搬旧前端 buildMenu 的条目与可用性判断——
    /// 离线只剩"备注名/复制地址/移除"；"用 USB 投屏"要有 USB 通道；"断开无线会话"要有 TLS 端口。
    /// </summary>
    private void Grid_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var item = ItemAt(e.OriginalSource as DependencyObject);
        if (item is null)
        {
            e.Handled = true;   // 点到表头/空白处不给菜单
            return;
        }
        dgDevices.SelectedItem = item;

        ContextMenu? menu = dgDevices.ContextMenu;
        if (menu is null) return;
        menu.Items.Clear();

        if (!item.IsOffline)
        {
            Add(menu, "投屏（自动选通道）", Vm?.CastCommand, item);
            if (item.IsUsb) Add(menu, "用 USB 投屏", Vm?.CastUsbCommand, item);
            Add(menu, "投屏（不同步剪贴板）", Vm?.CastNoClipCommand, item);
            Add(menu, "强制重新投屏（关掉旧窗口重开）", Vm?.CastForceCommand, item);
            menu.Items.Add(new Separator());
            Add(menu, "唤醒屏幕", Vm?.WakeScreenCommand, item);
            Add(menu, "返回", Vm?.SendBackCommand, item);
            Add(menu, "桌面", Vm?.SendHomeCommand, item);
            Add(menu, "多任务", Vm?.SendOverviewCommand, item);
            if (item.HasTls) Add(menu, "断开无线会话", Vm?.DisconnectDeviceCommand, item);
            menu.Items.Add(new Separator());

            // 文件互传（macOS 1.1.0 同款两项，只在在线分支）。这里直接搭 MenuItem：
            // 推送项要弹文件选择框，拉取项是三项子菜单，都不适合走 Add(menu, ...) 命令绑定。
            var push = new MenuItem { Header = "推送文件到设备…", IsEnabled = Vm is not null };
            push.Click += (_, _) => PromptPushFiles(item);
            menu.Items.Add(push);

            var pull = new MenuItem { Header = "从设备拉取文件", IsEnabled = Vm is not null };
            foreach (QuickPullDirectory directory in Vm?.Transfer.QuickPullDirectories
                         ?? Array.Empty<QuickPullDirectory>())
            {
                var child = new MenuItem { Header = "拉取 " + directory.DisplayName + " 目录" };
                child.Click += (_, _) => Vm?.Transfer.PullQuickDirectory(item.Key, directory);
                pull.Items.Add(child);
            }
            menu.Items.Add(pull);
        }

        Add(menu, "设置备注名…", Vm?.RequestAliasCommand, item);
        Add(menu, "复制地址", Vm?.CopyAddressCommand, item, enabled: item.Addr.Length > 0);
        Add(menu, "从列表移除", Vm?.RequestForgetCommand, item);
    }

    private static void Add(ContextMenu menu, string text, IRelayCommand<DeviceItem?>? command,
                            DeviceItem item, bool enabled = true)
    {
        menu.Items.Add(new MenuItem
        {
            Header = text,
            Command = command,
            CommandParameter = item,
            IsEnabled = enabled && command is not null,
        });
    }

    // ---- 文件拖放（FT-DRAG：仅在线行接收，悬停高亮 0.18） ----

    private DeviceItem? _dropRow;

    private void Grid_PreviewDragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop))
        {
            SetDropTarget(null);
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }

        DeviceItem? item = ItemAt(e.OriginalSource as DependencyObject);
        if (item is null || item.IsOffline || Vm is null)
        {
            SetDropTarget(null);
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }

        SetDropTarget(item);
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    private void Grid_PreviewDragLeave(object sender, DragEventArgs e)
    {
        // 行间移动也会触发 DragLeave，只有指针真的离开表格才清高亮（DragOver 会接力换行）。
        if (!dgDevices.IsMouseOver) SetDropTarget(null);
    }

    private void Grid_PreviewDrop(object sender, DragEventArgs e)
    {
        SetDropTarget(null);
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;

        DeviceItem? item = ItemAt(e.OriginalSource as DependencyObject);
        if (item is null || item.IsOffline) return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths && paths.Length > 0)
        {
            // 文件和文件夹都能拖；服务层按顶层投放项逐个推送（与 macOS FT-DRAG-2 一致）。
            Vm?.Transfer.PushFiles(item.Key, paths);
            e.Handled = true;
        }
    }

    /// <summary>同一时刻只让一行亮着；切行时先把旧行熄掉。</summary>
    private void SetDropTarget(DeviceItem? item)
    {
        if (ReferenceEquals(_dropRow, item)) return;
        if (_dropRow is not null) _dropRow.IsDropTargeted = false;
        _dropRow = item;
        if (_dropRow is not null) _dropRow.IsDropTargeted = true;
    }

    /// <summary>菜单「推送文件到设备…」：多选文件；文件夹走拖放（WPF 文件框不能混选目录）。</summary>
    private void PromptPushFiles(DeviceItem item)
    {
        var dialog = new OpenFileDialog
        {
            Title = "选择要推送到设备的文件",
            Filter = "所有文件 (*.*)|*.*",
            Multiselect = true,
            CheckFileExists = true,
            CheckPathExists = true,
        };
        if (dialog.ShowDialog(this) != true || dialog.FileNames.Length == 0) return;
        Vm?.Transfer.PushFiles(item.Key, dialog.FileNames);
    }

    // ---- 传输卡片 ----

    /// <summary>点击终态卡片关闭；进行中卡片只能点「取消」，点卡片本身不响应。</summary>
    private void TransferCard_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: TransferCardItem card }) return;
        if (HasButtonAncestor(e.OriginalSource as DependencyObject)) return;
        Vm?.Transfer.DismissCard(card);
    }

    private static bool HasButtonAncestor(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is ButtonBase) return true;
            source = source is Visual
                ? VisualTreeHelper.GetParent(source)
                : LogicalTreeHelper.GetParent(source);
        }
        return false;
    }

    private void Toast_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Vm?.HideToast();

    /// <summary>输入框回车 = 保存并应用（旧前端同一条快捷键）。</summary>
    private void ToolDirBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        Vm?.ApplyToolDirCommand.Execute(null);
        e.Handled = true;
    }

    /// <summary>
    /// 从事件源往上找所在行的数据对象。
    /// 命中的元素不一定是 Visual（比如 Run），所以父节点要分视觉树/逻辑树两种走法。
    /// </summary>
    private DeviceItem? ItemAt(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is DataGridRow row && row.Item is DeviceItem item) return item;
            source = source is Visual
                ? VisualTreeHelper.GetParent(source)
                : LogicalTreeHelper.GetParent(source);
        }
        return null;
    }

    protected override void OnClosed(EventArgs e)
    {
        Vm?.Stop();
        base.OnClosed(e);
    }
}
