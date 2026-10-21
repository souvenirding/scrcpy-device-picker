using CommunityToolkit.Mvvm.ComponentModel;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.ViewModels;

/// <summary>
/// 右下角一张传输卡片。Phase 复用 toast 的四态（running / ok / warn / err），
/// 终态卡片可点击关闭；进行中卡片只能点「取消」结束任务。
/// </summary>
public sealed partial class TransferCardItem : ObservableObject
{
    public string Id { get; } = Guid.NewGuid().ToString("N");

    /// <summary>关联任务；空串表示拒绝/提示类即时卡片（无进度、不可取消）。</summary>
    public string TaskId { get; init; } = string.Empty;

    [ObservableProperty]
    private string phase = "running";

    [ObservableProperty]
    private string title = string.Empty;

    [ObservableProperty]
    private string subtitle = string.Empty;

    /// <summary>0…100；null = 不定进度（测量失败或刚开始）。</summary>
    [ObservableProperty]
    private int? percent;

    public bool IsRunning => Phase == "running";

    public bool IsTerminal => !IsRunning;

    /// <summary>进行中才显示进度区与取消按钮（终态只留标题/副标题）。</summary>
    public bool ShowProgress => IsRunning;

    public bool ShowCancel => IsRunning;

    public bool IsIndeterminate => IsRunning && Percent is null;

    public double ProgressValue => Percent ?? 0;

    public string PercentText =>
        Percent is int value ? value + "%" : TransferText.IndeterminateProgress;

    /// <summary>终态符号；进行中用转圈的 ProgressRing（XAML 单独绑 IsRunning）。</summary>
    public string Glyph => Phase switch
    {
        "ok" => "✓",
        "err" => "✕",
        "warn" => "!",
        _ => "…",
    };

    partial void OnPhaseChanged(string value)
    {
        OnPropertyChanged(nameof(IsRunning));
        OnPropertyChanged(nameof(IsTerminal));
        OnPropertyChanged(nameof(ShowProgress));
        OnPropertyChanged(nameof(ShowCancel));
        OnPropertyChanged(nameof(IsIndeterminate));
        OnPropertyChanged(nameof(Glyph));
    }

    partial void OnPercentChanged(int? value)
    {
        OnPropertyChanged(nameof(IsIndeterminate));
        OnPropertyChanged(nameof(ProgressValue));
        OnPropertyChanged(nameof(PercentText));
    }

    public void UpdateProgress(string subtitleText, int? value)
    {
        Subtitle = subtitleText;
        Percent = value;
    }
}
