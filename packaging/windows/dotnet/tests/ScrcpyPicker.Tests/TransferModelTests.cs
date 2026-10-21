using System.IO;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;
using ScrcpyPicker.ViewModels;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 文件互传的纯逻辑层：候选通道、失败映射、落地命名、字节测量与文案。
/// 这些用例不需要真机，也不启动 adb；把 macOS 1.1.0 的契约钉在这里，
/// 以后改 Windows 实现时先看这里会不会红。
/// </summary>
public class TransferModelTests
{
    // ---- 严格 live-only 目标 ----

    [Fact]
    public void Candidates_keep_order_drop_empty_and_duplicates()
    {
        List<string> got = TransferTargets.Candidates(
            "serial", "usb-serial", "usb-serial", "192.0.2.5:37183", "");

        Assert.Equal(new[] { "usb-serial", "192.0.2.5:37183", "serial" }, got);
    }

    [Fact]
    public void ChooseLive_returns_first_device_and_ignores_offline_or_unauthorized()
    {
        var live = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["usb"] = "unauthorized",
            ["tls"] = "offline",
            ["tcp"] = "device",
        };

        Assert.Equal("tcp", TransferTargets.ChooseLive(new[] { "usb", "tls", "tcp" }, live));
    }

    [Fact]
    public void ChooseLive_returns_null_instead_of_falling_back()
    {
        var live = new Dictionary<string, string>(StringComparer.Ordinal) { ["usb"] = "offline" };
        Assert.Null(TransferTargets.ChooseLive(new[] { "usb", "tls" }, live));
    }

    // ---- 快捷目录（恰好三项，与 macOS FT-PULL-1 一致） ----

    [Fact]
    public void QuickPullDirectories_are_exactly_the_three_macos_contract_items()
    {
        Assert.Equal(3, QuickPullDirectory.All.Count);
        Assert.Equal(
            new[] { "Download", "DCIM", "Pictures" },
            QuickPullDirectory.All.Select(d => d.DisplayName));
        Assert.Equal(
            new[] { "/sdcard/Download", "/sdcard/DCIM", "/sdcard/Pictures" },
            QuickPullDirectory.All.Select(d => d.DevicePath));
    }

    // ---- 拉取落地名 ----

    [Fact]
    public void DestinationComposer_uses_suffix_when_the_name_is_taken()
    {
        using var tmp = new TempDir();
        Directory.CreateDirectory(tmp.Combine("DCIM"));
        File.WriteAllText(tmp.Combine("DCIM 2"), "occupied by a file");

        Assert.Equal("DCIM 3", PullDestinationComposer.FirstAvailableName("DCIM", tmp.Path));
    }

    [Fact]
    public void DestinationComposer_skips_names_reserved_by_running_tasks()
    {
        using var tmp = new TempDir();
        var reserved = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Pictures", "Pictures 2" };

        Assert.Equal("Pictures 3",
            PullDestinationComposer.FirstAvailableName("Pictures", tmp.Path, reserved));
    }

    [Fact]
    public void DestinationComposer_keeps_the_plain_name_when_free()
    {
        using var tmp = new TempDir();
        Assert.Equal("Download", PullDestinationComposer.FirstAvailableName("Download", tmp.Path));
    }

    // ---- adb 输出 → 失败原因 ----

    [Fact]
    public void FailureMapper_maps_device_offline_before_anything_else()
    {
        TransferFailure f = TransferFailureMapper.Map(
            TransferDirection.Push, "adb: error: device offline", 1);

        Assert.Equal(TransferFailureKind.DeviceDisconnected, f.Kind);
        Assert.Equal("设备连接中断", f.DisplayText);
    }

    [Fact]
    public void FailureMapper_no_space_means_device_full_for_push_and_local_full_for_pull()
    {
        const string output = "adb: error: failed to copy: No space left on device";

        Assert.Equal(TransferFailureKind.DeviceStorageFull,
            TransferFailureMapper.Map(TransferDirection.Push, output, 1).Kind);
        Assert.Equal(TransferFailureKind.LocalDiskFull,
            TransferFailureMapper.Map(TransferDirection.Pull, output, 1).Kind);
    }

    [Fact]
    public void FailureMapper_pull_missing_directory_carries_the_display_name()
    {
        TransferFailure f = TransferFailureMapper.Map(
            TransferDirection.Pull,
            "ls: /sdcard/DCIM: No such file or directory", 1, "DCIM");

        Assert.Equal(TransferFailureKind.DirectoryMissing, f.Kind);
        Assert.Equal("设备上没有该目录：DCIM", f.DisplayText);
    }

    [Fact]
    public void FailureMapper_unknown_keeps_first_meaningful_line()
    {
        TransferFailure f = TransferFailureMapper.Map(
            TransferDirection.Push, "\n  adb: error: weird failure\r\ntrailing", 1);

        Assert.Equal(TransferFailureKind.Unknown, f.Kind);
        Assert.Equal("adb: error: weird failure", f.DisplayText);
    }

    // ---- 本机字节测量 ----

    [Fact]
    public void LocalItemSize_sums_files_recursively_and_returns_zero_when_missing()
    {
        using var tmp = new TempDir();
        Directory.CreateDirectory(tmp.Combine("sub"));
        File.WriteAllBytes(tmp.Combine("a.bin"), new byte[7]);
        File.WriteAllBytes(tmp.Combine("sub", "b.bin"), new byte[11]);

        Assert.Equal(18, LocalItemSize.Bytes(tmp.Path));
        Assert.Equal(11, LocalItemSize.Bytes(tmp.Combine("sub", "b.bin")));
        Assert.Equal(0, LocalItemSize.Bytes(tmp.Combine("nope")));
    }

    // ---- 文案 ----

    [Theory]
    [InlineData(1, 1, "a.txt", "a.txt")]
    [InlineData(2, 3, "b.txt", "第 2/3 个 · b.txt")]
    public void FileSubtitle_matches_batch_contract(int index, int total, string name, string want) =>
        Assert.Equal(want, TransferRules.FileSubtitle(name, index, total));

    [Theory]
    [InlineData(TransferStartStatus.RejectedOffline, "该设备当前离线，无法接收文件")]
    [InlineData(TransferStartStatus.RejectedDeviceBusy, "该设备正在传输文件，请稍候")]
    [InlineData(TransferStartStatus.RejectedGlobalLimit, "已有 3 个传输在进行，请稍后再试")]
    [InlineData(TransferStartStatus.FailedAdbMissing, "adb 不可用")]
    [InlineData(TransferStartStatus.FailedUnreachable, "设备当前不可达")]
    public void NoticeText_covers_every_rejection(TransferStartStatus status, string want) =>
        Assert.Equal(want, TransferText.NoticeText(new TransferStartResult(status)));

    // ---- 行内状态优先级（启动中… > 传输中 > 离线 / 在线） ----

    [Fact]
    public void DeviceItem_state_prioritises_casting_then_transfer_then_offline()
    {
        var offline = new WebRow { Key = "k", Offline = true };
        var online = new WebRow { Key = "k" };

        Assert.Equal("启动中…", new DeviceItem(offline, casting: true, transferring: true).StateText);
        Assert.Equal("传输中", new DeviceItem(offline, casting: false, transferring: true).StateText);
        Assert.Equal("离线", new DeviceItem(offline, casting: false).StateText);
        Assert.Equal("在线", new DeviceItem(online, casting: false).StateText);
    }
}

/// <summary>
/// 受理前的五重判定里，不需要真 adb 就能覆盖的三条：
/// 空选择、adb 未解析、设备不在线。互斥与全局额度需要真实任务，留给设备冒烟。
/// </summary>
public class TransferManagerAcceptanceTests
{
    private static TransferManager MakeManager(
        TempDir temp, bool adbResolved, params WebRow[] rows)
    {
        var tools = new ToolchainHolder(new ToolchainSnapshot
        {
            AdbResolved = adbResolved,
            AdbPath = adbResolved ? "adb.exe" : string.Empty,
        });
        var cfg = new ConfigService(temp.Path);
        var discovery = new DiscoveryService(tools, cfg);
        List<WebRow> snapshot = rows.ToList();
        return new TransferManager(tools, discovery, () => snapshot);
    }

    [Fact]
    public void Empty_push_selection_fails_without_queueing()
    {
        using var temp = new TempDir();
        using var manager = MakeManager(temp, true);
        TransferStartResult r = manager.StartPush("k", Array.Empty<string>());

        Assert.Equal(TransferStartStatus.Failed, r.Status);
        Assert.Equal("没有选择要推送的文件", r.Failure?.DisplayText);
    }

    [Fact]
    public void Missing_adb_is_reported_as_adb_unavailable_not_as_offline_device()
    {
        using var temp = new TempDir();
        using var manager = MakeManager(temp, false, new WebRow { Key = "k", Online = true });
        TransferStartResult r = manager.StartPull("k", QuickPullDirectory.Download);

        Assert.Equal(TransferStartStatus.FailedAdbMissing, r.Status);
        Assert.Equal("adb 不可用", TransferText.NoticeText(r));
    }

    [Fact]
    public void Offline_device_is_rejected_before_any_process_starts()
    {
        using var temp = new TempDir();
        using var manager = MakeManager(temp, true, new WebRow { Key = "k", Offline = true });
        TransferStartResult r = manager.StartPush("k", new[] { "a.txt" });

        Assert.Equal(TransferStartStatus.RejectedOffline, r.Status);
        Assert.Equal("该设备当前离线，无法接收文件", TransferText.NoticeText(r));
    }

    [Fact]
    public void Unknown_device_key_is_treated_as_offline()
    {
        using var temp = new TempDir();
        using var manager = MakeManager(temp, true);
        TransferStartResult r = manager.StartPull("ghost", QuickPullDirectory.Dcim);

        Assert.Equal(TransferStartStatus.RejectedOffline, r.Status);
    }
}
