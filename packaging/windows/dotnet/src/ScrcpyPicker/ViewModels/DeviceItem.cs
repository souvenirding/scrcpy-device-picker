using CommunityToolkit.Mvvm.ComponentModel;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.ViewModels;

/// <summary>
/// 设备表一行。列表每 10 秒整体重建，所以"正在启动投屏""正在传输文件"这类瞬时状态
/// 由 MainViewModel / TransferCenter 用 Key 集合记住后再贴回来，不能被重绘刷没了
/// （旧前端与 macOS 版同款处理）。其余字段来自 WebRow，构造后不变。
/// </summary>
public sealed partial class DeviceItem : ObservableObject
{
    public DeviceItem(WebRow row, bool casting, bool transferring = false)
    {
        Row = row;
        // 生成器用的就是下面那个 isCasting 字段本身（属性名靠首字母大写推出来），
        // 所以这里写 isCasting，不带下划线前缀。
        isCasting = casting;
        isTransferring = transferring;
    }

    [ObservableProperty]
    private bool isCasting;

    /// <summary>该行是否有进行中的文件传输（TransferCenter 维护，重绘时贴回）。</summary>
    [ObservableProperty]
    private bool isTransferring;

    /// <summary>该行是否为当前拖拽悬停的放置目标（只影响背景，离线行不会亮起）。</summary>
    [ObservableProperty]
    private bool isDropTargeted;

    public WebRow Row { get; }

    public string Key => Row.Key;
    public string Name => Row.Name;
    public string Model => Row.Model;
    public string Android => Row.Android;
    public string ConnText => Row.ConnText;
    public string Addr => Row.Addr;
    public string BatteryText => Row.BatteryText;
    public bool IsOffline => Row.Offline;
    public bool IsUsb => Row.Usb;
    public bool HasTls => Row.Tls.Length > 0;

    /// <summary>状态列文案（优先级与 macOS 一致：启动中… &gt; 传输中 &gt; 离线 / 在线）。</summary>
    public string StateText => IsCasting ? "启动中…"
        : IsTransferring ? TransferText.TransferringRowStatus
        : IsOffline ? "离线" : "在线";

    partial void OnIsCastingChanged(bool value) => OnPropertyChanged(nameof(StateText));

    partial void OnIsTransferringChanged(bool value) => OnPropertyChanged(nameof(StateText));
}
