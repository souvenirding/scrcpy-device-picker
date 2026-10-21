using System.Diagnostics;
using System.IO;
using System.Text;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>
/// 文件互传服务层（移植 macOS 1.1.0 的 TransferManager 契约）。
///
/// 规矩与 macOS 版一致：
///   * 受理在锁内原子完成：adb 可用 → 行在线 → 每设备互斥 → 全局 3 个上限 → 登记；
///   * 传输目标严格现算，只认 adb 当前列为 device 的候选，不退回缓存；
///   * 字节实测进度：推送看设备端 stat/du，拉取看本机落地目录；
///   * 取消由用户主动触发，终止 adb 进程并清理半包；
///   * 所有进度/终态回调都跑到后台线程，界面层自己切回 UI 线程。
/// </summary>
public sealed class TransferManager : IDisposable
{
    private sealed class ActiveTask
    {
        public required string TaskId { get; init; }
        public required string DeviceKey { get; init; }
        public required TransferDirection Direction { get; init; }
        public bool Cancelled { get; set; }
        public string ReservedDestinationName { get; set; } = string.Empty;
    }

    private static readonly UTF8Encoding Utf8NoBom = new(false);

    private readonly ToolchainHolder _tools;
    private readonly DiscoveryService _discovery;
    private readonly Func<List<WebRow>> _rows;
    private readonly object _gate = new();

    /// <summary>per-device 活动表，同时承担每设备互斥与全局计数。</summary>
    private readonly Dictionary<string, ActiveTask> _active = new(StringComparer.Ordinal);

    /// <summary>taskId → 正在跑的 adb 进程（取消与退出清理用）。</summary>
    private readonly Dictionary<string, Process> _processes = new(StringComparer.Ordinal);

    public event Action<TransferProgress>? ProgressChanged;
    public event Action<TransferFinal>? FinalChanged;

    public TransferManager(
        ToolchainHolder tools,
        DiscoveryService discovery,
        Func<List<WebRow>> rows)
    {
        _tools = tools;
        _discovery = discovery;
        _rows = rows;
    }

    // ---- 受理 ----

    public TransferStartResult StartPush(string deviceKey, IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            return new TransferStartResult(TransferStartStatus.Failed,
                Failure: new TransferFailure(TransferFailureKind.Unknown,
                    Summary: TransferText.NoFilesSelected));
        }

        (TransferStartResult result, ActiveTask? task) = Accept(deviceKey, TransferDirection.Push);
        if (task is null) return result;

        string[] copy = paths.ToArray();
        _ = Task.Run(() => RunPushGuarded(task, copy));
        return result;
    }

    public TransferStartResult StartPull(string deviceKey, QuickPullDirectory directory)
    {
        (TransferStartResult result, ActiveTask? task) = Accept(deviceKey, TransferDirection.Pull);
        if (task is null) return result;

        _ = Task.Run(() => RunPullGuarded(task, directory));
        return result;
    }

    /// <summary>五重判定 + 登记，全部在同一把锁内完成（拒绝式返回，不排队）。</summary>
    private (TransferStartResult Result, ActiveTask? Task) Accept(
        string deviceKey, TransferDirection direction)
    {
        lock (_gate)
        {
            if (!_tools.Get().AdbResolved)
                return (new TransferStartResult(TransferStartStatus.FailedAdbMissing), null);

            WebRow? row = _rows().FirstOrDefault(r => r.Key == deviceKey && !r.Offline);
            if (row is null)
                return (new TransferStartResult(TransferStartStatus.RejectedOffline), null);

            if (_active.ContainsKey(deviceKey))
                return (new TransferStartResult(TransferStartStatus.RejectedDeviceBusy), null);

            if (_active.Count >= TransferRules.MaxConcurrentTransfers)
                return (new TransferStartResult(TransferStartStatus.RejectedGlobalLimit), null);

            var task = new ActiveTask
            {
                TaskId = Guid.NewGuid().ToString("N"),
                DeviceKey = deviceKey,
                Direction = direction,
            };
            _active[deviceKey] = task;
            return (TransferStartResult.Start(task.TaskId), task);
        }
    }

    // ---- 取消 ----

    public void Cancel(string taskId)
    {
        Process? process = null;
        lock (_gate)
        {
            ActiveTask? task = _active.Values.FirstOrDefault(t => t.TaskId == taskId);
            if (task is null || task.Cancelled) return;   // 幂等
            task.Cancelled = true;
            _processes.TryGetValue(taskId, out process);
        }
        if (process is not null) TryKill(process);
    }

    public void CancelAll()
    {
        var processes = new List<Process>();
        lock (_gate)
        {
            foreach (ActiveTask task in _active.Values) task.Cancelled = true;
            processes.AddRange(_processes.Values);
        }
        foreach (Process p in processes) TryKill(p);
    }

    public void Dispose()
    {
        CancelAll();
        ProgressChanged = null;
        FinalChanged = null;
    }

    private bool IsCancelled(ActiveTask task)
    {
        lock (_gate) return task.Cancelled;
    }

    private HashSet<string> ReservedDestinationNames()
    {
        lock (_gate)
        {
            return new HashSet<string>(
                _active.Values.Select(t => t.ReservedDestinationName)
                    .Where(n => n.Length > 0),
                StringComparer.OrdinalIgnoreCase);
        }
    }

    // ---- 推送 ----

    private void RunPushGuarded(ActiveTask task, string[] paths)
    {
        try
        {
            RunPush(task, paths);
        }
        catch (Exception ex)
        {
            PublishFinal(FailedFinal(task, new TransferFailure(
                TransferFailureKind.Unknown, Summary: ex.Message)));
        }
    }

    private void RunPush(ActiveTask task, string[] paths)
    {
        ToolchainSnapshot tc = _tools.Get();
        if (!tc.AdbResolved)
        {
            PublishFinal(FailedFinal(task,
                new TransferFailure(TransferFailureKind.AdbUnavailable)));
            return;
        }

        string? transport = LiveTransport(task.DeviceKey);
        if (transport is null)
        {
            PublishFinal(FailedFinal(task,
                new TransferFailure(TransferFailureKind.DeviceUnreachable)));
            return;
        }

        // 每任务一次 mkdir -p：既是目录保障，也是文件夹 push 落到 <目标>/<文件夹名> 的前提。
        CmdResult mkdir = ProcessRunner.Run(tc.AdbPath,
            new[] { "-s", transport, "shell", "mkdir", "-p", TransferRules.DevicePushDirectory },
            15000);
        if (mkdir.Status != 0)
        {
            PublishFinal(FailedFinal(task, new TransferFailure(
                TransferFailureKind.Unknown, Summary: FirstLine(mkdir.Text))));
            return;
        }

        int totalFiles = paths.Length;
        int successCount = 0;
        int failureCount = 0;
        TransferFailure? firstFailure = null;

        for (int offset = 0; offset < paths.Length; offset++)
        {
            if (IsCancelled(task))
            {
                PublishFinal(CancelledFinal(task));
                return;
            }

            string source = paths[offset];
            string fileName = ItemName(source);
            int index = offset + 1;
            PublishProgress(new TransferProgress(
                task.TaskId, index, totalFiles, fileName, null));

            bool isDirectory = Directory.Exists(source);
            string devicePath = TransferRules.DevicePushDirectory + "/" + fileName;
            CancellationTokenSource? poller = StartPoller(
                LocalItemSize.Bytes(source),
                TransferRules.PushProgressPollMs,
                () => isDirectory
                    ? DeviceItemSize.Bytes(tc.AdbPath, transport, devicePath) ?? 0
                    : DeviceItemSize.FileBytes(tc.AdbPath, transport, devicePath) ?? 0,
                percent => PublishProgress(new TransferProgress(
                    task.TaskId, index, totalFiles, fileName, percent)));

            (int code, string output) = RunProcess(task, tc.AdbPath,
                new[] { "-s", transport, "push", source, TransferRules.DevicePushTarget });
            StopPoller(poller);

            if (IsCancelled(task))
            {
                // 当前项在设备端可能留下半包，删掉再发 cancelled。
                ProcessRunner.Run(tc.AdbPath,
                    new[] { "-s", transport, "shell", "rm", "-rf", devicePath }, 15000);
                PublishFinal(CancelledFinal(task));
                return;
            }

            if (code == 0)
            {
                successCount++;
            }
            else
            {
                failureCount++;
                firstFailure ??= TransferFailureMapper.Map(
                    TransferDirection.Push, output, code);
            }
        }

        PublishFinal(new TransferFinal(task.TaskId, task.DeviceKey, TransferDirection.Push,
            Summarize(successCount, failureCount, firstFailure)));
    }

    // ---- 拉取 ----

    private void RunPullGuarded(ActiveTask task, QuickPullDirectory directory)
    {
        try
        {
            RunPull(task, directory);
        }
        catch (Exception ex)
        {
            PublishFinal(FailedFinal(task, new TransferFailure(
                TransferFailureKind.Unknown, Summary: ex.Message)));
        }
    }

    private void RunPull(ActiveTask task, QuickPullDirectory directory)
    {
        ToolchainSnapshot tc = _tools.Get();
        if (!tc.AdbResolved)
        {
            PublishFinal(FailedFinal(task,
                new TransferFailure(TransferFailureKind.AdbUnavailable)));
            return;
        }

        string? transport = LiveTransport(task.DeviceKey);
        if (transport is null)
        {
            PublishFinal(FailedFinal(task,
                new TransferFailure(TransferFailureKind.DeviceUnreachable)));
            return;
        }

        // 预检 ls -A：同时判存在与判空；预检失败不占用落地名。
        CmdResult probe = ProcessRunner.Run(tc.AdbPath,
            new[] { "-s", transport, "shell", "ls", "-A", directory.DevicePath }, 15000);
        string lower = probe.Text.ToLowerInvariant();
        if (ContainsAny(lower, "No such file or directory", "does not exist"))
        {
            PublishFinal(FailedFinal(task, new TransferFailure(
                TransferFailureKind.DirectoryMissing, directory.DisplayName)));
            return;
        }
        if (probe.Status != 0)
        {
            PublishFinal(FailedFinal(task, TransferFailureMapper.Map(
                TransferDirection.Pull, probe.Text, probe.Status, directory.DisplayName)));
            return;
        }
        if (probe.Text.Trim().Length == 0)
        {
            // 空目录不是失败：warn 卡片，不发起 pull、不创建本地目录。
            PublishFinal(FailedFinal(task,
                new TransferFailure(TransferFailureKind.DirectoryEmpty)));
            return;
        }

        string downloads = TransferPaths.DownloadsDirectory();
        string destinationName = PullDestinationComposer.FirstAvailableName(
            directory.DisplayName, downloads, ReservedDestinationNames());
        lock (_gate)
        {
            if (_active.TryGetValue(task.DeviceKey, out ActiveTask? record) &&
                record.TaskId == task.TaskId)
            {
                record.ReservedDestinationName = destinationName;
            }
        }
        string destination = Path.Combine(downloads, destinationName);

        if (IsCancelled(task))
        {
            PublishFinal(CancelledFinal(task));
            return;
        }

        long totalBytes = DeviceItemSize.Bytes(tc.AdbPath, transport, directory.DevicePath) ?? 0;
        PublishProgress(new TransferProgress(
            task.TaskId, 1, 1, directory.DisplayName, null));

        CancellationTokenSource? poller = StartPoller(
            totalBytes,
            TransferRules.PullProgressPollMs,
            () => LocalItemSize.Bytes(destination),
            percent => PublishProgress(new TransferProgress(
                task.TaskId, 1, 1, directory.DisplayName, percent)));

        (int code, string output) = RunProcess(task, tc.AdbPath,
            new[] { "-s", transport, "pull", directory.DevicePath, destination });
        StopPoller(poller);

        if (IsCancelled(task))
        {
            // 落地名是本次新分配的，删掉不会碰用户既有文件。
            try { if (Directory.Exists(destination)) Directory.Delete(destination, true); }
            catch { /* 清理失败不影响终态 */ }
            PublishFinal(CancelledFinal(task));
            return;
        }

        TransferOutcome outcome = code == 0
            ? TransferOutcome.Succeeded(1)
            : new TransferOutcome(TransferOutcomeKind.Failed,
                FirstFailure: TransferFailureMapper.Map(
                    TransferDirection.Pull, output, code, directory.DisplayName));

        PublishFinal(new TransferFinal(
            task.TaskId, task.DeviceKey, TransferDirection.Pull, outcome));
    }

    // ---- 目标现算 ----

    /// <summary>
    /// 按 [preferred, usbSerial, tls, tcp5555] 候选序，与 adb 实时输出匹配；
    /// 无 live 候选返回 null（绝不退回 cands[0]）。
    /// </summary>
    private string? LiveTransport(string deviceKey)
    {
        WebRow? row = _rows().FirstOrDefault(r => r.Key == deviceKey);
        if (row is null) return null;

        List<string> candidates = TransferTargets.Candidates(
            string.Empty, row.Preferred, row.UsbSerial, row.Tls, row.Tcp5555);
        if (candidates.Count == 0) return null;

        return TransferTargets.ChooseLive(candidates, _discovery.LiveTransports());
    }

    // ---- 进程执行与取消 ----

    private (int Code, string Output) RunProcess(
        ActiveTask task, string exe, string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Utf8NoBom,
            StandardErrorEncoding = Utf8NoBom,
            WorkingDirectory = Path.GetDirectoryName(exe) ?? string.Empty,
        };
        foreach (string arg in args) psi.ArgumentList.Add(arg);

        using var process = new Process { StartInfo = psi };
        lock (_gate) _processes[task.TaskId] = process;

        try
        {
            process.Start();
            Task<string> outTask = process.StandardOutput.ReadToEndAsync();
            Task<string> errTask = process.StandardError.ReadToEndAsync();

            // 取消可能发生在 Start 之前的窄窗口里：登记后自查一次。
            if (IsCancelled(task)) TryKill(process);

            process.WaitForExit();
            string stdout = AwaitText(outTask);
            string stderr = AwaitText(errTask);
            string output = stderr.Length == 0 ? stdout
                : stdout.Length == 0 ? stderr
                : stdout + "\n" + stderr;
            return (process.ExitCode, output);
        }
        catch (Exception ex)
        {
            return (-1, "无法启动 adb：" + ex.Message);
        }
        finally
        {
            lock (_gate) _processes.Remove(task.TaskId);
            try { process.Dispose(); } catch { /* 已退出 */ }
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch
        {
            // 还没 Start 或已经退出：都算取消成功，执行器会在进程退出后收束。
        }
    }

    private static string AwaitText(Task<string> task)
    {
        try
        {
            return task.Wait(TimeSpan.FromSeconds(3)) ? task.Result : string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    // ---- 字节实测进度 ----

    /// <summary>
    /// 每 250ms（推送）/ 1s（拉取）实测一次已传输字节，百分比变化才回调。
    /// 总字节为 0 时不启动，界面保持「传输中…」的降级态。
    /// </summary>
    private static CancellationTokenSource? StartPoller(
        long totalBytes, int intervalMs, Func<long> measure, Action<int> onChange)
    {
        if (totalBytes <= 0) return null;

        var cts = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(TransferRules.ProgressInitialDelayMs, cts.Token);
                int lastPercent = -1;
                while (true)
                {
                    long bytes = 0;
                    try { bytes = measure(); } catch { /* 单次测量失败保持上一拍 */ }
                    int percent = (int)Math.Clamp(bytes * 100 / totalBytes, 0, 100);
                    if (percent != lastPercent)
                    {
                        lastPercent = percent;
                        onChange(percent);
                    }
                    await Task.Delay(intervalMs, cts.Token);
                }
            }
            catch (OperationCanceledException)
            {
                // 正常收尾
            }
            catch
            {
                // 轮询是锦上添花，任何异常都不能影响传输本身
            }
        });
        return cts;
    }

    private static void StopPoller(CancellationTokenSource? cts)
    {
        try { cts?.Cancel(); } catch { /* 已收尾 */ }
    }

    // ---- 终态发布 ----

    private void PublishProgress(TransferProgress progress)
    {
        Action<TransferProgress>? callback = ProgressChanged;
        try { callback?.Invoke(progress); } catch { /* 界面层异常不能打断传输 */ }
    }

    private void PublishFinal(TransferFinal final)
    {
        Action<TransferFinal>? callback;
        lock (_gate)
        {
            if (_active.TryGetValue(final.DeviceKey, out ActiveTask? task) &&
                task.TaskId == final.TaskId)
            {
                _active.Remove(final.DeviceKey);
            }
            _processes.Remove(final.TaskId);
            callback = FinalChanged;
        }
        try { callback?.Invoke(final); } catch { /* 同上 */ }
    }

    private static TransferFinal FailedFinal(ActiveTask task, TransferFailure failure) =>
        new(task.TaskId, task.DeviceKey, task.Direction,
            new TransferOutcome(TransferOutcomeKind.Failed, FirstFailure: failure));

    private static TransferFinal CancelledFinal(ActiveTask task) =>
        new(task.TaskId, task.DeviceKey, task.Direction,
            new TransferOutcome(TransferOutcomeKind.Cancelled));

    private static TransferOutcome Summarize(
        int successCount, int failureCount, TransferFailure? firstFailure)
    {
        if (failureCount == 0) return TransferOutcome.Succeeded(successCount);
        if (successCount > 0)
        {
            return new TransferOutcome(TransferOutcomeKind.PartialFailure,
                successCount, failureCount,
                firstFailure ?? new TransferFailure(TransferFailureKind.Unknown));
        }
        return new TransferOutcome(TransferOutcomeKind.Failed,
            FirstFailure: firstFailure ?? new TransferFailure(TransferFailureKind.Unknown));
    }

    // ---- 小工具 ----

    private static bool ContainsAny(string haystack, params string[] needles)
    {
        foreach (string needle in needles)
        {
            if (haystack.Contains(needle, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static string FirstLine(string? text)
    {
        if (string.IsNullOrEmpty(text)) return string.Empty;
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.Trim('\r', ' ', '\t');
            if (line.Length > 0) return line;
        }
        return string.Empty;
    }

    /// <summary>顶层投放项的名字；尾部分隔符（文件夹）不能把文件名变成空串。</summary>
    private static string ItemName(string path)
    {
        string trimmed = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string name = Path.GetFileName(trimmed);
        return name.Length > 0 ? name : path;
    }
}
