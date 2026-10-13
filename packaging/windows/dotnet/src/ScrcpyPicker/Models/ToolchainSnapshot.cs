namespace ScrcpyPicker.Models;

/// <summary>
/// 一次工具链解析的不可变快照（对应 Go 的 toolchain.Toolchain）。
/// 构造后不改动；要换目录是整体换掉 Holder 里指向的那一份，
/// 这样发现线程、投屏、界面并发读到的都是同一套自洽的值。
/// </summary>
public sealed record ToolchainSnapshot
{
    public string AdbPath { get; init; } = string.Empty;
    public string ScrcpyPath { get; init; } = string.Empty;

    /// <summary>adb 所在目录（诊断与"往这里放东西"的展示用）。</summary>
    public string ToolDir { get; init; } = string.Empty;

    /// <summary>scrcpy 所在目录；scrcpy-server 与 exe 同级，启动时当工作目录用。</summary>
    public string ScrcpyDir { get; init; } = string.Empty;

    public bool AdbResolved { get; init; }
    public bool ScrcpyResolved { get; init; }

    /// <summary>命中来源：override/config/exe-tools/exe-dir/exe-relative/known/path/scan/none。</summary>
    public string AdbSource { get; init; } = "none";
    public string ScrcpySource { get; init; } = "none";

    /// <summary>启动 scrcpy 的工作目录（找不到 scrcpy 时退回 adb 目录）。</summary>
    public string WorkDir => ScrcpyDir.Length > 0 ? ScrcpyDir : ToolDir;

    public static ToolchainSnapshot Empty { get; } = new();
}

/// <summary>
/// 可热替换的工具链容器（对应 Go 的 atomic.Pointer 包壳）。
/// 用户在界面上改了 adb 目录后，所有使用方下一次读取立刻看到新值，不需要重启程序。
/// </summary>
public sealed class ToolchainHolder
{
    private volatile ToolchainSnapshot _current = ToolchainSnapshot.Empty;

    public ToolchainHolder(ToolchainSnapshot initial) => _current = initial;

    public ToolchainSnapshot Get() => _current;

    public void Set(ToolchainSnapshot value) => _current = value;
}
