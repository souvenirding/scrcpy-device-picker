using CommunityToolkit.Mvvm.ComponentModel;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.ViewModels;

/// <summary>
/// 设备表一行。列表每 10 秒整体重建，所以"正在启动投屏"这种瞬时状态
/// 由 MainViewModel 用 Key 集合记住后再贴回来，不能被重绘刷没了（旧前端同款处理）。
/// 其余字段来自 WebRow，构造后不变，只有 IsCasting 需要通知界面。
/// </summary>
public sealed partial class DeviceItem : ObservableObject
{
    public DeviceItem(WebRow row, bool casting)
    {
        Row = row;
        // 生成器用的就是下面那个 isCasting 字段本身（属性名靠首字母大写推出来），
        // 所以这里写 isCasting，不带下划线前缀。
        isCasting = casting;
    }

    [ObservableProperty]
    private bool isCasting;

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

    /// <summary>状态列文案。</summary>
    public string StateText => IsCasting ? "启动中…" : IsOffline ? "离线" : "在线";

    partial void OnIsCastingChanged(bool value) => OnPropertyChanged(nameof(StateText));
}
