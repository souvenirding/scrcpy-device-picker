using System.Collections.ObjectModel;
using System.IO;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.ViewModels;

/// <summary>
/// 传输卡片区与设备行状态的界面中枢（对应 macOS 的 TransferViewModel）。
///
/// 线程规矩：服务层回调从后台线程来，这里统一 <see cref="Dispatcher.BeginInvoke"/>
/// 切回 UI 线程后再碰任何可观察状态；卡片按「进行中优先、同相位按入列序」取前三张，
/// 其余折成「+N 个传输中」。
/// </summary>
public sealed partial class TransferCenter : ObservableObject, IDisposable
{
    private readonly TransferManager _manager;
    private readonly Func<string, string> _displayName;
    private readonly Dispatcher _dispatcher;

    private readonly List<TransferCardItem> _all = new();
    private readonly Dictionary<string, TransferCardItem> _byTask = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _pullDirectoryNames = new(StringComparer.Ordinal);
    private readonly HashSet<string> _activeKeys = new(StringComparer.Ordinal);

    public ObservableCollection<TransferCardItem> VisibleCards { get; } = new();

    [ObservableProperty]
    private string overflowText = string.Empty;

    /// <summary>右键「从设备拉取文件」子菜单的数据源（恰好三项）。</summary>
    public IReadOnlyList<QuickPullDirectory> QuickPullDirectories => QuickPullDirectory.All;

    /// <summary>行内「传输中」状态变化（已切到 UI 线程）。</summary>
    public event Action<string, bool>? DeviceTransferStateChanged;

    public TransferCenter(
        TransferManager manager,
        Func<string, string> displayName,
        Dispatcher dispatcher)
    {
        _manager = manager;
        _displayName = displayName;
        _dispatcher = dispatcher;

        _manager.ProgressChanged += OnManagerProgress;
        _manager.FinalChanged += OnManagerFinal;
    }

    public bool IsTransferring(string deviceKey) => _activeKeys.Contains(deviceKey);

    // ---- 命令入口 ----

    public void PushFiles(string deviceKey, IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        string name = _displayName(deviceKey);
        TransferStartResult result = _manager.StartPush(deviceKey, paths);
        HandleStart(result, deviceKey, name, TransferDirection.Push,
            fileName: TopLevelName(paths[0]), totalFiles: paths.Count);
    }

    public void PullQuickDirectory(string deviceKey, QuickPullDirectory directory)
    {
        string name = _displayName(deviceKey);
        TransferStartResult result = _manager.StartPull(deviceKey, directory);
        if (result.Status == TransferStartStatus.Started)
        {
            _pullDirectoryNames[result.TaskId] = directory.DisplayName;
        }
        HandleStart(result, deviceKey, name, TransferDirection.Pull,
            fileName: directory.DisplayName, totalFiles: 1);
    }

    [RelayCommand]
    private void CancelCard(TransferCardItem? card)
    {
        if (card is { IsRunning: true } && card.TaskId.Length > 0)
        {
            _manager.Cancel(card.TaskId);
        }
    }

    /// <summary>点击终态卡片关闭；进行中卡片不响应（避免误关看不见进度）。</summary>
    public void DismissCard(TransferCardItem card)
    {
        if (card.IsRunning) return;
        if (_all.Remove(card)) Rebuild();
    }

    public void Dispose()
    {
        _manager.ProgressChanged -= OnManagerProgress;
        _manager.FinalChanged -= OnManagerFinal;
        _manager.Dispose();
    }

    // ---- 受理 ----

    private void HandleStart(
        TransferStartResult result,
        string deviceKey,
        string deviceName,
        TransferDirection direction,
        string fileName,
        int totalFiles)
    {
        if (result.Status == TransferStartStatus.Started)
        {
            string title = direction == TransferDirection.Push
                ? string.Format(TransferText.PushRunningFormat, deviceName)
                : string.Format(TransferText.PullRunningFormat, deviceName);
            var card = new TransferCardItem
            {
                TaskId = result.TaskId,
                Phase = "running",
                Title = title,
                Subtitle = TransferRules.FileSubtitle(fileName, 1, totalFiles),
                Percent = null,
            };
            _byTask[result.TaskId] = card;
            _activeKeys.Add(deviceKey);
            DeviceTransferStateChanged?.Invoke(deviceKey, true);
            AddCard(card);
            return;
        }

        bool isFailure = result.Status is
            TransferStartStatus.FailedUnreachable or TransferStartStatus.Failed;
        AddNotice(
            TransferText.NoticeText(result),
            isFailure ? "err" : "warn",
            isFailure ? TransferRules.FailureCardMs : TransferRules.NoticeCardMs);
    }

    private void AddNotice(string text, string phase, int durationMs)
    {
        if (text.Length == 0) return;
        var card = new TransferCardItem
        {
            Phase = phase,
            Title = text,
        };
        AddCard(card);
        ScheduleRemoval(card, durationMs);
    }

    // ---- 服务层回调（后台线程 → UI 线程） ----

    private void OnManagerProgress(TransferProgress progress) =>
        PostToUi(() => ApplyProgress(progress));

    private void OnManagerFinal(TransferFinal final) =>
        PostToUi(() => ApplyFinal(final));

    private void ApplyProgress(TransferProgress progress)
    {
        if (!_byTask.TryGetValue(progress.TaskId, out TransferCardItem? card)) return;
        card.UpdateProgress(
            TransferRules.FileSubtitle(progress.FileName, progress.FileIndex, progress.TotalFiles),
            progress.Percent);
    }

    private void ApplyFinal(TransferFinal final)
    {
        _activeKeys.Remove(final.DeviceKey);
        DeviceTransferStateChanged?.Invoke(final.DeviceKey, false);

        if (!_byTask.Remove(final.TaskId, out TransferCardItem? card))
        {
            _pullDirectoryNames.Remove(final.TaskId);
            return;
        }

        string deviceName = _displayName(final.DeviceKey);
        string directoryName = _pullDirectoryNames.TryGetValue(final.TaskId, out string? dir)
            ? dir
            : string.Empty;
        _pullDirectoryNames.Remove(final.TaskId);

        TransferOutcome outcome = final.Outcome;
        string phase;
        string title;
        string subtitle = string.Empty;
        int durationMs;

        switch (outcome.Kind)
        {
            case TransferOutcomeKind.Succeeded:
                phase = "ok";
                durationMs = TransferRules.SuccessCardMs;
                title = final.Direction == TransferDirection.Push
                    ? string.Format(TransferText.PushSucceededFormat,
                        deviceName, outcome.SuccessCount)
                    : string.Format(TransferText.PullSucceededFormat, directoryName);
                break;

            case TransferOutcomeKind.PartialFailure:
                phase = "warn";
                durationMs = TransferRules.FailureCardMs;
                title = string.Format(TransferText.PartialFailureFormat,
                    outcome.SuccessCount, outcome.FailureCount);
                subtitle = outcome.FirstFailure?.DisplayText ?? string.Empty;
                break;

            case TransferOutcomeKind.Cancelled:
                phase = "warn";
                durationMs = TransferRules.NoticeCardMs;
                title = final.Direction == TransferDirection.Push
                    ? TransferText.PushCancelled
                    : TransferText.PullCancelled;
                break;

            default:
                TransferFailure reason = outcome.FirstFailure
                    ?? new TransferFailure(TransferFailureKind.Unknown);
                if (reason.Kind == TransferFailureKind.DirectoryEmpty)
                {
                    // 空目录不是失败：warn 呈现，3 秒收起。
                    phase = "warn";
                    durationMs = TransferRules.NoticeCardMs;
                    title = reason.DisplayText;
                }
                else
                {
                    phase = "err";
                    durationMs = TransferRules.FailureCardMs;
                    title = final.Direction == TransferDirection.Push
                        ? TransferText.PushFailed
                        : TransferText.PullFailed;
                    subtitle = reason.DisplayText;
                }
                break;
        }

        card.Phase = phase;
        card.Title = title;
        card.Subtitle = subtitle;
        card.Percent = null;

        Rebuild();
        ScheduleRemoval(card, durationMs);
    }

    // ---- 卡片堆叠与计时 ----

    private void AddCard(TransferCardItem card)
    {
        _all.Add(card);
        Rebuild();
    }

    /// <summary>进行中置顶，其余按入列序；最多三张，多余折成汇总行。</summary>
    private void Rebuild()
    {
        List<TransferCardItem> ordered = _all
            .OrderBy(c => c.IsRunning ? 0 : 1)
            .ToList();
        List<TransferCardItem> visible = ordered
            .Take(TransferRules.MaxVisibleCards)
            .ToList();

        VisibleCards.Clear();
        foreach (TransferCardItem card in visible) VisibleCards.Add(card);

        OverflowText = ordered.Count > visible.Count
            ? string.Format(TransferText.OverflowSummaryFormat, ordered.Count - visible.Count)
            : string.Empty;
    }

    private void ScheduleRemoval(TransferCardItem card, int durationMs)
    {
        _ = RemoveAfterAsync(card, durationMs);
    }

    private async Task RemoveAfterAsync(TransferCardItem card, int durationMs)
    {
        try { await Task.Delay(durationMs); } catch { return; }
        PostToUi(() =>
        {
            if (_all.Remove(card)) Rebuild();
        });
    }

    private void PostToUi(Action action)
    {
        try
        {
            if (_dispatcher.CheckAccess()) action();
            else _dispatcher.BeginInvoke(action);
        }
        catch
        {
            // 窗口关闭后 dispatcher 已停：忽略迟到的回调。
        }
    }

    private static string TopLevelName(string path)
    {
        string trimmed = path.TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string name = Path.GetFileName(trimmed);
        return name.Length > 0 ? name : path;
    }
}
