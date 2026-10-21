using System.IO;

namespace ScrcpyPicker.Models;

/// <summary>传输方向：Push = 电脑 → 设备；Pull = 设备 → 电脑。</summary>
public enum TransferDirection
{
    Push,
    Pull,
}

/// <summary>
/// 设备端常用拉取目录。名字与路径和 macOS 版 <c>QuickPullDirectory</c> 完全一致，
/// 菜单文案与落地目录名共用 DisplayName。
/// </summary>
public sealed record QuickPullDirectory(string DisplayName, string DevicePath)
{
    public static readonly QuickPullDirectory Download = new("Download", "/sdcard/Download");
    public static readonly QuickPullDirectory Dcim = new("DCIM", "/sdcard/DCIM");
    public static readonly QuickPullDirectory Pictures = new("Pictures", "/sdcard/Pictures");

    /// <summary>恰好三项，与 macOS 版同一份契约（增删只改这里）。</summary>
    public static readonly IReadOnlyList<QuickPullDirectory> All =
        new[] { Download, Dcim, Pictures };
}

/// <summary>受理结果七分支（对齐 macOS <c>TransferStartResult</c>）。</summary>
public enum TransferStartStatus
{
    Started,
    RejectedOffline,
    RejectedDeviceBusy,
    RejectedGlobalLimit,
    FailedAdbMissing,
    FailedUnreachable,
    Failed,
}

public sealed record TransferStartResult(
    TransferStartStatus Status,
    string TaskId = "",
    TransferFailure? Failure = null)
{
    public static TransferStartResult Start(string taskId) =>
        new(TransferStartStatus.Started, taskId);
}

/// <summary>adb 输出映射出的失败原因；文案集中在 <see cref="DisplayText"/>。</summary>
public enum TransferFailureKind
{
    DeviceDisconnected,
    DeviceStorageFull,
    LocalDiskFull,
    DeviceUnreachable,
    AdbUnavailable,
    DirectoryMissing,
    DirectoryEmpty,
    Unknown,
}

public sealed record TransferFailure(
    TransferFailureKind Kind,
    string DirectoryName = "",
    string Summary = "")
{
    public string DisplayText => Kind switch
    {
        TransferFailureKind.DeviceDisconnected => "设备连接中断",
        TransferFailureKind.DeviceStorageFull => "设备存储空间不足",
        TransferFailureKind.LocalDiskFull => "本机磁盘空间不足",
        TransferFailureKind.DeviceUnreachable => "设备当前不可达",
        TransferFailureKind.AdbUnavailable => "adb 不可用",
        TransferFailureKind.DirectoryMissing =>
            DirectoryName.Length > 0 ? "设备上没有该目录：" + DirectoryName : "设备上没有该目录",
        TransferFailureKind.DirectoryEmpty => "目录为空，没有拉取到文件",
        _ => Summary.Length > 0 ? Summary : "adb 执行失败",
    };
}

/// <summary>进度快照；Percent 为 null 表示降级为不定进度。</summary>
public sealed record TransferProgress(
    string TaskId,
    int FileIndex,
    int TotalFiles,
    string FileName,
    int? Percent);

public enum TransferOutcomeKind
{
    Succeeded,
    PartialFailure,
    Failed,
    Cancelled,
}

public sealed record TransferOutcome(
    TransferOutcomeKind Kind,
    int SuccessCount = 0,
    int FailureCount = 0,
    TransferFailure? FirstFailure = null)
{
    public static TransferOutcome Succeeded(int fileCount) =>
        new(TransferOutcomeKind.Succeeded, SuccessCount: fileCount);
}

/// <summary>任务终态（服务层在后台线程发出，界面层负责切回 UI 线程）。</summary>
public sealed record TransferFinal(
    string TaskId,
    string DeviceKey,
    TransferDirection Direction,
    TransferOutcome Outcome);

/// <summary>用户可见文案集中处，视图与 ViewModel 不内联字符串。</summary>
public static class TransferText
{
    public const string PushRunningFormat = "正在推送到 {0}…";
    public const string PullRunningFormat = "正在从 {0} 拉取…";
    public const string PushSucceededFormat = "已推送到 {0} · {1} 个文件";
    public const string PullSucceededFormat = "已拉取到下载文件夹 · {0}";
    public const string PartialFailureFormat = "{0} 个成功 · {1} 个失败";
    public const string PushFailed = "推送失败";
    public const string PullFailed = "拉取失败";
    public const string PushCancelled = "推送已取消";
    public const string PullCancelled = "拉取已取消";
    public const string BatchProgressFormat = "第 {0}/{1} 个";
    public const string OverflowSummaryFormat = "+{0} 个传输中";
    public const string IndeterminateProgress = "传输中…";
    public const string TransferringRowStatus = "传输中";

    public const string RejectedOffline = "该设备当前离线，无法接收文件";
    public const string RejectedDeviceBusy = "该设备正在传输文件，请稍候";
    public const string RejectedGlobalLimit = "已有 3 个传输在进行，请稍后再试";
    public const string NoFilesSelected = "没有选择要推送的文件";

    /// <summary>受理拒绝分支 → 提示文案（对齐 macOS 异常映射表）。</summary>
    public static string NoticeText(TransferStartResult result) => result.Status switch
    {
        TransferStartStatus.RejectedOffline => RejectedOffline,
        TransferStartStatus.RejectedDeviceBusy => RejectedDeviceBusy,
        TransferStartStatus.RejectedGlobalLimit => RejectedGlobalLimit,
        TransferStartStatus.FailedAdbMissing => "adb 不可用",
        TransferStartStatus.FailedUnreachable => "设备当前不可达",
        TransferStartStatus.Failed => result.Failure?.DisplayText ?? "传输没有开始",
        _ => string.Empty,
    };
}

/// <summary>传输的固定规则与常量（对齐 macOS <c>TransferConstants</c>）。</summary>
public static class TransferRules
{
    /// <summary>推送目标目录（固定不可配置）。</summary>
    public const string DevicePushDirectory = "/sdcard/Download";

    /// <summary>尾斜杠让 adb 按「目标为已存在目录」写入其下。</summary>
    public const string DevicePushTarget = DevicePushDirectory + "/";

    /// <summary>每设备互斥 + 全局并发上限（与 macOS 一致）。</summary>
    public const int MaxConcurrentTransfers = 3;

    /// <summary>卡片区同时渲染上限，超出走汇总行。</summary>
    public const int MaxVisibleCards = 3;

    public const int PushProgressPollMs = 250;
    public const int PullProgressPollMs = 1000;
    public const int ProgressInitialDelayMs = 300;
    public const long BytesPerDuBlock = 1024;

    /// <summary>卡片自动消失时长：成功 3 秒，失败 8 秒，提示/取消 3 秒。</summary>
    public const int SuccessCardMs = 3000;
    public const int FailureCardMs = 8000;
    public const int NoticeCardMs = 3000;

    /// <summary>批量任务副标题「第 i/N 个 · 文件名」；单文件只留文件名。</summary>
    public static string FileSubtitle(string fileName, int fileIndex, int totalFiles) =>
        totalFiles > 1
            ? string.Format(TransferText.BatchProgressFormat, fileIndex, totalFiles) + " · " + fileName
            : fileName;
}

/// <summary>
/// 传输目标严格 live-only 现算：只接受 adb 当前真的列为 device 的候选。
/// 与投屏的 ResolveTarget 不同，这里绝不退回首选，否则会把「设备不可达」
/// 错报成别的失败（对齐 macOS D-TARGET）。
/// </summary>
public static class TransferTargets
{
    /// <summary>候选顺序：首选 → USB → 无线调试 → TCP 5555 → Key；去空、去重、保序。</summary>
    public static List<string> Candidates(
        string key, string preferred, string usbSerial, string tls, string tcp5555)
    {
        var cands = new List<string>();
        foreach (string c in new[] { preferred, usbSerial, tls, tcp5555, key })
        {
            if (c.Length == 0 || cands.Contains(c)) continue;
            cands.Add(c);
        }
        return cands;
    }

    /// <summary>第一个 state == device 的候选；一个都没有返回 null。</summary>
    public static string? ChooseLive(
        IEnumerable<string> candidates,
        IReadOnlyDictionary<string, string> live)
    {
        foreach (string c in candidates)
        {
            if (live.TryGetValue(c, out string? state) && state == "device") return c;
        }
        return null;
    }
}

/// <summary>
/// 拉取落地名：&lt;下载目录&gt;\&lt;目录名&gt;，已存在则「目录名 2」「目录名 3」…
/// 同时排除活动表里已登记的名字（防并发拉取同名目录撞车）。
/// </summary>
public static class PullDestinationComposer
{
    public const string Separator = " ";
    public const int MaxAttempts = 1000;

    public static string FirstAvailableName(
        string baseName, string directory, ISet<string>? reserved = null)
    {
        reserved ??= new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string candidate = baseName;
        for (int index = 2; index <= MaxAttempts; index++)
        {
            if (!reserved.Contains(candidate) &&
                !Directory.Exists(Path.Combine(directory, candidate)) &&
                !File.Exists(Path.Combine(directory, candidate)))
            {
                return candidate;
            }
            candidate = baseName + Separator + index;
        }
        return candidate;
    }
}

/// <summary>adb 输出 → 中文失败原因（匹配顺序自上而下，首中即返）。</summary>
public static class TransferFailureMapper
{
    private static readonly string[] Disconnected =
    {
        "device offline", "device not found", "not found", "device unauthorized",
        "connection reset", "protocol fault", "closed",
    };

    private static readonly string[] NoSpace = { "No space left on device" };
    private static readonly string[] DirMissing = { "No such file or directory", "does not exist" };

    public static TransferFailure Map(
        TransferDirection direction,
        string output,
        int exitCode,
        string directoryName = "")
    {
        _ = exitCode;
        string haystack = (output ?? string.Empty).ToLowerInvariant();

        foreach (string pattern in Disconnected)
        {
            if (haystack.Contains(pattern.ToLowerInvariant(), StringComparison.Ordinal))
                return new TransferFailure(TransferFailureKind.DeviceDisconnected);
        }
        foreach (string pattern in NoSpace)
        {
            if (haystack.Contains(pattern.ToLowerInvariant(), StringComparison.Ordinal))
                return new TransferFailure(direction == TransferDirection.Push
                    ? TransferFailureKind.DeviceStorageFull
                    : TransferFailureKind.LocalDiskFull);
        }
        if (direction == TransferDirection.Pull)
        {
            foreach (string pattern in DirMissing)
            {
                if (haystack.Contains(pattern.ToLowerInvariant(), StringComparison.Ordinal))
                    return new TransferFailure(TransferFailureKind.DirectoryMissing, directoryName);
            }
        }
        return new TransferFailure(TransferFailureKind.Unknown, Summary: FirstMeaningfulLine(output));
    }

    private static string FirstMeaningfulLine(string? text)
    {
        if (string.IsNullOrEmpty(text)) return string.Empty;
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.Trim('\r', ' ', '\t');
            if (line.Length > 0) return line;
        }
        return string.Empty;
    }
}

/// <summary>本机文件/目录字节数（目录递归）。取不到返回 0，调用方降级为不定进度。</summary>
public static class LocalItemSize
{
    public static long Bytes(string path)
    {
        try
        {
            if (File.Exists(path)) return new FileInfo(path).Length;
            if (!Directory.Exists(path)) return 0;

            long total = 0;
            foreach (string file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
            {
                try { total += new FileInfo(file).Length; } catch { /* 单个文件读不到不影响整体 */ }
            }
            return total;
        }
        catch
        {
            return 0;
        }
    }
}

/// <summary>设备端大小测量（adb shell du / stat），失败返回 null。</summary>
public static class DeviceItemSize
{
    /// <summary>递归汇总（文件与目录皆可）：du -sk，KiB → 字节。低频场景用。</summary>
    public static long? Bytes(string adbPath, string transport, string path)
    {
        var r = Services.ProcessRunner.Run(
            adbPath, new[] { "-s", transport, "shell", "du", "-sk", path }, 30000);
        if (r.Status != 0) return null;
        long? blocks = FirstInteger(r.Text);
        return blocks is null ? null : blocks.Value * TransferRules.BytesPerDuBlock;
    }

    /// <summary>单文件大小（不递归）：stat -c %s，O(1)，推送高频轮询专用。</summary>
    public static long? FileBytes(string adbPath, string transport, string path)
    {
        var r = Services.ProcessRunner.Run(
            adbPath, new[] { "-s", transport, "shell", "stat", "-c", "%s", path }, 15000);
        if (r.Status != 0) return null;
        return FirstInteger(r.Text);
    }

    private static long? FirstInteger(string text)
    {
        foreach (string token in (text ?? string.Empty).Split(
                     new[] { '\t', ' ', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (long.TryParse(token, out long value)) return value;
        }
        return null;
    }
}
