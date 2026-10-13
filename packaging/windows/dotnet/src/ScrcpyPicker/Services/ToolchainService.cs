using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using ScrcpyPicker.Models;

namespace ScrcpyPicker.Services;

/// <summary>一次解析的输入，字段都可以为空（对应 Go 的 toolchain.Options）。</summary>
public sealed record ResolveOptions
{
    /// <summary>exe 所在目录。</summary>
    public string ExeDir { get; init; } = string.Empty;

    /// <summary>devices.json 里记住的工具目录。</summary>
    public string ConfigDir { get; init; } = string.Empty;

    /// <summary>SCRCPY_TOOL_DIR 或 -tools 的值。</summary>
    public string EnvDir { get; init; } = string.Empty;

    /// <summary>是否允许兜底自动搜索。</summary>
    public bool AllowScan { get; init; } = true;

    /// <summary>自动搜索的时间上限，null 用默认 8 秒（界面里传 10 秒，与 Go 版一致）。</summary>
    public TimeSpan? ScanBudget { get; init; }
}

/// <summary>
/// adb / scrcpy 的定位与调用（移植自 Go 版 internal/toolchain）。
///
/// 解析顺序：
///   1. SCRCPY_TOOL_DIR / -tools（手动覆盖）
///   2. 配置里记住的目录
///   3. exe 同级 tools、platform-tools、exe 目录本身
///   4. exe 相对位置（..\\scrcpy、..\\..\\scrcpy，仓库开发态）
///   5. 常见安装位置（Android SDK、Program Files、scoop、choco…）
///   6. PATH
///   7. 兜底：固定盘受限深度自动搜索（只在前面全落空时跑，命中由调用方写回配置）
/// 找不到 adb 时 AdbResolved=false —— 路径问题和"没有设备"是两码事，不能混报。
/// </summary>
public static class ToolchainService
{
    public const string SourceOverride = "override";
    public const string SourceConfig = "config";
    public const string SourceExeTools = "exe-tools";
    public const string SourceExeDir = "exe-dir";
    public const string SourceExeRelative = "exe-relative";
    public const string SourceKnown = "known";
    public const string SourcePath = "path";
    public const string SourceScan = "scan";
    public const string SourceNone = "none";

    private static readonly TimeSpan DefaultScanBudget = TimeSpan.FromSeconds(8);

    // ---- 候选目录 ----

    /// <summary>候选目录 + 命中来源标签。</summary>
    public sealed record DirCandidate(string Dir, string Source);

    /// <summary>按优先级列出候选目录（已去重，Windows 上大小写不敏感）。</summary>
    public static List<DirCandidate> BuildCandidates(ResolveOptions o)
    {
        var outList = new List<DirCandidate>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void Add(string? dir, string src)
        {
            if (string.IsNullOrWhiteSpace(dir)) return;
            string trimmed = dir.Trim();
            if (!seen.Add(trimmed)) return;
            outList.Add(new DirCandidate(trimmed, src));
        }

        Add(o.EnvDir, SourceOverride);
        Add(o.ConfigDir, SourceConfig);
        if (!string.IsNullOrWhiteSpace(o.ExeDir))
        {
            Add(Path.Combine(o.ExeDir, "tools"), SourceExeTools);
            Add(Path.Combine(o.ExeDir, "platform-tools"), SourceExeTools);
            Add(o.ExeDir, SourceExeDir);
            Add(Path.Combine(o.ExeDir, "..", "scrcpy"), SourceExeRelative);
            Add(Path.Combine(o.ExeDir, "..", "..", "scrcpy"), SourceExeRelative);
        }
        foreach (string d in KnownDirs()) Add(d, SourceKnown);
        return outList;
    }

    /// <summary>本机常见的 adb / scrcpy 安装位置（存在与否交给调用方判断）。</summary>
    public static List<string> KnownDirs()
    {
        var outList = new List<string>();
        string FirstEnv(params string[] names)
        {
            foreach (var n in names)
            {
                string? v = Environment.GetEnvironmentVariable(n);
                if (!string.IsNullOrEmpty(v)) return v;
            }
            return string.Empty;
        }

        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string appLocal = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string choco = Environment.GetEnvironmentVariable("ChocolateyInstall") ?? string.Empty;

        string sdk = FirstEnv("ANDROID_HOME", "ANDROID_SDK_ROOT");
        if (sdk.Length > 0) outList.Add(Path.Combine(sdk, "platform-tools"));

        if (appLocal.Length > 0)
        {
            outList.Add(Path.Combine(appLocal, "Android", "Sdk", "platform-tools"));
            outList.Add(Path.Combine(appLocal, "Programs", "scrcpy"));
            outList.Add(Path.Combine(appLocal, "scrcpy"));
        }
        if (home.Length > 0)
        {
            outList.Add(Path.Combine(home, "scoop", "apps", "platform-tools", "current"));
            outList.Add(Path.Combine(home, "scoop", "apps", "scrcpy", "current"));
        }

        foreach (string pf in ProgramFilesDirs())
        {
            outList.Add(Path.Combine(pf, "platform-tools"));
            outList.Add(Path.Combine(pf, "scrcpy"));
        }
        if (choco.Length > 0) outList.Add(Path.Combine(choco, "bin"));

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            outList.Add(@"C:\platform-tools");
            outList.Add(@"C:\scrcpy");
            outList.Add(@"D:\platform-tools");
        }
        else
        {
            outList.Add("/opt/homebrew/bin");
            outList.Add("/usr/local/bin");
        }
        return outList;
    }

    private static IEnumerable<string> ProgramFilesDirs()
    {
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        if (pf.Length > 0) yield return pf;
        if (pf86.Length > 0) yield return pf86;
    }

    // ---- 解析 ----

    /// <summary>按候选顺序定位 adb 与 scrcpy。adb 与 scrcpy 分别解析，允许来自不同目录。</summary>
    public static ToolchainSnapshot Resolve(ResolveOptions o)
    {
        var cands = BuildCandidates(o);
        string adbPath = string.Empty, adbSource = SourceNone, toolDir = string.Empty;

        bool adbResolved = false;

        foreach (var c in cands)
        {
            string? p = ResolveExe(Path.Combine(c.Dir, "adb"));
            if (p is null) continue;
            adbPath = p; adbResolved = true; adbSource = c.Source; toolDir = c.Dir;
            break;
        }
        if (!adbResolved)
        {
            string? fromPath = LookPath("adb");
            if (fromPath is not null)
            {
                adbPath = fromPath; adbResolved = true; adbSource = SourcePath;
                toolDir = Path.GetDirectoryName(fromPath) ?? string.Empty;
            }
        }

        // 兜底自动搜索：Search 返回的是目录，必须再拼出 adb 的可执行文件路径。
        if (!adbResolved && o.AllowScan)
        {
            List<string> hits = Search(o.ScanBudget ?? DefaultScanBudget);
            string best = PickBest(hits);
            if (best.Length > 0)
            {
                string? p = ResolveExe(Path.Combine(best, "adb"));
                if (p is not null)
                {
                    adbPath = p; adbResolved = true; adbSource = SourceScan; toolDir = best;
                }
            }
        }

        // ---- scrcpy：优先 adb 同级（同一份发行包），再遍历候选，最后 PATH ----
        string scrcpyPath = string.Empty, scrcpySource = SourceNone, scrcpyDir = string.Empty;
        bool scrcpyResolved = false;

        if (toolDir.Length > 0)
        {
            string? p = ResolveExe(Path.Combine(toolDir, "scrcpy"));
            if (p is not null)
            {
                scrcpyPath = p; scrcpyResolved = true; scrcpySource = adbSource; scrcpyDir = toolDir;
            }
        }
        if (!scrcpyResolved)
        {
            foreach (var c in cands)
            {
                string? p = ResolveExe(Path.Combine(c.Dir, "scrcpy"));
                if (p is null) continue;
                scrcpyPath = p; scrcpyResolved = true; scrcpySource = c.Source; scrcpyDir = c.Dir;
                break;
            }
        }
        if (!scrcpyResolved)
        {
            string? fromPath = LookPath("scrcpy");
            if (fromPath is not null)
            {
                scrcpyPath = fromPath; scrcpyResolved = true; scrcpySource = SourcePath;
                scrcpyDir = Path.GetDirectoryName(fromPath) ?? string.Empty;
            }
        }

        // 都没找到也给个展示用目录，界面提示"往这里放东西"。
        if (toolDir.Length == 0)
        {
            if (o.ConfigDir.Length > 0) toolDir = o.ConfigDir;
            else if (o.EnvDir.Length > 0) toolDir = o.EnvDir;
            else if (o.ExeDir.Length > 0) toolDir = Path.Combine(o.ExeDir, "tools");
        }

        return new ToolchainSnapshot
        {
            AdbPath = adbPath,
            ScrcpyPath = scrcpyPath,
            ToolDir = toolDir,
            ScrcpyDir = scrcpyDir,
            AdbResolved = adbResolved,
            ScrcpyResolved = scrcpyResolved,
            AdbSource = adbSource,
            ScrcpySource = scrcpySource,
        };
    }

    /// <summary>目录里是否有 adb 可执行文件。用于校验用户手填的目录，不能借用候选链。</summary>
    public static bool HasAdb(string dir) => ResolveExe(Path.Combine(dir, "adb")) is not null;

    /// <summary>目录里是否有 scrcpy 可执行文件。</summary>
    public static bool HasScrcpy(string dir) => ResolveExe(Path.Combine(dir, "scrcpy")) is not null;

    /// <summary>跑一次受限深度自动搜索，返回候选目录（adb+scrcpy 齐全的排前面）。</summary>
    public static List<string> ScanFor(TimeSpan budget) => Search(budget);

    /// <summary>返回带正确扩展名的可执行文件路径；找不到返回 null。</summary>
    public static string? ResolveExe(string @base)
    {
        foreach (string ext in ExeExtensions())
        {
            string p = @base + ext;
            if (File.Exists(p)) return p;
        }
        return null;
    }

    private static IEnumerable<string> ExeExtensions()
    {
        yield return string.Empty;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            yield return ".exe";
            yield return ".cmd";
            yield return ".bat";
        }
    }

    /// <summary>等价于 Go 的 exec.LookPath：按 PATH 逐项找带扩展名的文件。</summary>
    public static string? LookPath(string name)
    {
        string? pathVar = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathVar)) return null;
        foreach (string dir in pathVar.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            string candidate = Path.Combine(dir.Trim('"'), name);
            string? hit = ResolveExe(candidate);
            if (hit is not null) return hit;
        }
        return null;
    }

    // ---- 受限深度目录搜索 ----

    /// <summary>
    /// 只认目录名本身是 platform-tools / scrcpy 的目录。
    /// 不做子串匹配：探针时 C:\Windows\WinSxS 下几百个名字里带 "adb" 哈希串的系统目录会被误当候选。
    /// </summary>
    public static readonly Regex ScanNameRe = new(
        @"^(platform[-_]?tools|scrcpy[\w.\-]*)$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    /// <summary>
    /// 不进入的目录名（系统/缓存目录，噪音极大且不可能有 adb.exe）。
    /// 显式写成 false 的项是给同类前缀"放行"用的（字典里有键即以这里的值为准）。
    /// </summary>
    public static readonly Dictionary<string, bool> ScanSkipDirs = new(StringComparer.OrdinalIgnoreCase)
    {
        ["windows"] = true, ["winsxs"] = true, ["boot"] = true, ["perflogs"] = true,
        ["$recycle.bin"] = true, ["system volume information"] = true, ["$winreagent"] = true,
        ["recovery"] = true, ["appdata"] = true, ["programdata"] = true, ["temp"] = true,
        ["tmp"] = true, ["node_modules"] = true, [".git"] = true, ["dosdevices"] = true,
        ["windowsold"] = true,
        ["library"] = false, // macOS 的 ~/Library 要进（Android sdk 在那），显式放行
    };

    public const int ScanMaxDepth = 3;    // 相对盘根：E:\Flash\tools\scrcpy 刚好第 3 层
    public const int ScanMaxDirs = 8000;  // 最多看多少个目录，防止极端机器卡住启动
    public const int ScanMaxHits = 60;    // 候选上限

    /// <summary>
    /// 在可搜索的根（Windows=固定盘）下做受限深度广度优先搜索，
    /// 返回含 adb 且目录名像 platform-tools / scrcpy 的目录，已排序。
    /// 超出时间或目录预算就返回已找到的部分。
    /// </summary>
    public static List<string> Search(TimeSpan budget, IEnumerable<string>? roots = null)
    {
        if (budget <= TimeSpan.Zero) budget = DefaultScanBudget;
        List<string> rootList = (roots ?? SearchRoots()).ToList();
        if (rootList.Count == 0) return new List<string>();

        DateTime deadline = DateTime.UtcNow + budget;
        var hits = new List<string>();
        var queue = new Queue<(string Path, int Depth)>();
        foreach (string r in rootList) queue.Enqueue((r, 0));
        int visited = 0;

        while (queue.Count > 0)
        {
            if (DateTime.UtcNow > deadline || visited >= ScanMaxDirs || hits.Count >= ScanMaxHits) break;
            (string path, int depth) = queue.Dequeue();
            visited++;

            string baseName = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (depth > 0 && IsSkipped(baseName)) continue;

            IEnumerable<string> entries;
            try
            {
                entries = Directory.EnumerateDirectories(path);
            }
            catch
            {
                continue; // 权限不足/正在被卸载：跳过，不中断整轮搜索
            }

            foreach (string full in entries)
            {
                string name = Path.GetFileName(full);
                if (IsSkipped(name)) continue;
                if (!IsRealDir(full)) continue; // 联接点/符号链接不进，防止绕圈
                if (ScanNameRe.IsMatch(name) && ResolveExe(Path.Combine(full, "adb")) is not null)
                {
                    hits.Add(full);
                }
                if (depth + 1 < ScanMaxDepth) queue.Enqueue((full, depth + 1));
            }
        }
        return RankHits(hits);
    }

    public static bool IsSkipped(string name) =>
        ScanSkipDirs.TryGetValue(name, out bool skip) && skip;

    /// <summary>排除符号链接/联接点指向的目录（重复进入会白白吃掉搜索预算）。</summary>
    public static bool IsRealDir(string path)
    {
        try
        {
            var info = new DirectoryInfo(path);
            info.Refresh();
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0) return false;
            return info.Exists;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>"adb 与 scrcpy 同目录"的排前面（一份完整发行包最省事），其次路径浅的优先。</summary>
    public static List<string> RankHits(List<string> hits)
    {
        int Score(string p)
        {
            int s = ResolveExe(Path.Combine(p, "scrcpy")) is not null ? -10 : 0;
            return s + p.Split(Path.DirectorySeparatorChar).Length;
        }

        return hits.OrderBy(Score).ThenBy(p => p, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public static string PickBest(List<string> hits) => hits.Count > 0 ? hits[0] : string.Empty;

    /// <summary>可搜索的根目录：Windows 上是所有固定盘（可移动盘/网络盘/光驱不进）。</summary>
    public static List<string> SearchRoots()
    {
        var roots = new List<string>();
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return roots;
        try
        {
            uint mask = Kernel32.GetLogicalDrives();
            for (int i = 0; i < 26; i++)
            {
                if ((mask & (1u << i)) == 0) continue;
                string root = $"{(char)('A' + i)}:\\";
                if (Kernel32.GetDriveType(root) == Kernel32.DriveType.Fixed) roots.Add(root);
            }
        }
        catch
        {
            // 极端情况（连 kernel32 都调不动）退回 DriveInfo；
            // 这里的 DriveType 要写全，否则会和 Kernel32.DriveType 撞名。
            foreach (var d in DriveInfo.GetDrives())
            {
                if (d.DriveType == System.IO.DriveType.Fixed) roots.Add(d.RootDirectory.FullName);
            }
        }
        return roots;
    }

    // ---- 提示文案 ----

    /// <summary>
    /// "未找到 adb"时给用户的指引。这里是 Windows 专用版本：
    /// 绝不能提 brew，也不能让 macOS 用户去找 adb.exe（macOS 走 Swift 那份界面）。
    /// </summary>
    public const string MissingHint =
        "未找到 adb：已按 SCRCPY_TOOL_DIR → 已保存目录 → exe 同级 tools → PATH → 常见安装位置 → 自动搜索 依次查找。" +
        "三种办法任选：① 把 adb.exe / AdbWinApi.dll / AdbWinUsbApi.dll 与 scrcpy.exe 及其 dll 放进 exe 旁边的 tools 目录；" +
        "② 在下方填入含 adb.exe 的文件夹（例如 E:\\Flash\\tools\\scrcpy）后点「保存并应用」；③ 点「自动搜索」让程序在本机找。";

    /// <summary>命中来源的中文标签（界面直接展示）。</summary>
    public static string SourceLabel(string source) => source switch
    {
        SourceOverride => "指定目录（-tools / SCRCPY_TOOL_DIR）",
        SourceConfig => "已保存目录",
        SourceExeTools => "exe 同级 tools",
        SourceExeDir => "exe 所在目录",
        SourceExeRelative => "exe 相对目录",
        SourceKnown => "常见安装位置",
        SourcePath => "PATH",
        SourceScan => "自动搜索",
        _ => "未找到",
    };

    // ---- adb 调用助手（对应 Go 的 Adb / AdbText / ShellProp / AdbVersion / ScrcpyVersion）----

    public static string[] Adb(ToolchainSnapshot t, IEnumerable<string> args)
    {
        if (!t.AdbResolved) return Array.Empty<string>();
        return ProcessRunner.Run(t.AdbPath, args).Lines;
    }

    public static string AdbText(ToolchainSnapshot t, IEnumerable<string> args)
    {
        if (!t.AdbResolved) return string.Empty;
        return ProcessRunner.Run(t.AdbPath, args).Text;
    }

    public static string ShellProp(ToolchainSnapshot t, string serial, string cmd)
    {
        string[] lines = Adb(t, new[] { "-s", serial, "shell", cmd });
        return string.Join("\n", lines).Trim();
    }

    public static string AdbVersion(ToolchainSnapshot t)
    {
        if (!t.AdbResolved) return string.Empty;
        string[] lines = ProcessRunner.Run(t.AdbPath, new[] { "version" }).Lines;
        return lines.Length > 0 ? lines[0] : string.Empty;
    }

    public static string ScrcpyVersion(ToolchainSnapshot t)
    {
        if (t.ScrcpyPath.Length == 0 || !File.Exists(t.ScrcpyPath)) return string.Empty;
        string[] lines = ProcessRunner.Run(t.ScrcpyPath, new[] { "--version" }).Lines;
        return lines.Length > 0 ? lines[0] : string.Empty;
    }
}
