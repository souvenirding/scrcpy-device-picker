using System.IO;
using ScrcpyPicker.Models;
using ScrcpyPicker.Services;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 工具链定位：候选顺序、扩展名匹配、受限深度搜索的边界。
///
/// 这些规则决定的是"exe 拿到一台新机器能不能自己找到 adb"，
/// 所以搜索用例都指向临时目录，不依赖本机装了些什么。
/// </summary>
[Collection(EnvCollectionDefinition.Name)]
public class ToolchainServiceTests
{
    // ---- 候选顺序 ----

    [Fact]
    public void BuildCandidates_ordersOverrideThenConfigThenExeRelative()
    {
        var cands = ToolchainService.BuildCandidates(new ResolveOptions
        {
            EnvDir = @"T:\env",
            ConfigDir = @"T:\cfg",
            ExeDir = @"T:\app",
        });

        Assert.Equal(ToolchainService.SourceOverride, cands[0].Source);
        Assert.Equal(@"T:\env", cands[0].Dir);
        Assert.Equal(ToolchainService.SourceConfig, cands[1].Source);
        Assert.Equal(@"T:\cfg", cands[1].Dir);
        Assert.Equal(ToolchainService.SourceExeTools, cands[2].Source);
        Assert.Equal(Path.Combine(@"T:\app", "tools"), cands[2].Dir);
        Assert.Equal(Path.Combine(@"T:\app", "platform-tools"), cands[3].Dir);
        Assert.Equal(ToolchainService.SourceExeDir, cands[4].Source);
        Assert.Equal(@"T:\app", cands[4].Dir);
        Assert.All(cands, c => Assert.False(string.IsNullOrWhiteSpace(c.Dir)));
    }

    [Fact]
    public void BuildCandidates_dedupesIgnoringCase_andSkipsBlanks()
    {
        var cands = ToolchainService.BuildCandidates(new ResolveOptions
        {
            EnvDir = "  T:\\Same  ",
            ConfigDir = "t:\\same",
            ExeDir = "   ",
        });

        // 去重按"去空白后整串比较、大小写不敏感"，与 Go 版一致；
        // 只差一个结尾反斜杠的写法算两个候选（多跑一次 File.Exists 而已，不影响选中的目录）。
        Assert.Equal(@"T:\Same", cands[0].Dir);
        Assert.Equal(ToolchainService.SourceOverride, cands[0].Source);
        Assert.Single(cands.Where(c => c.Dir.Equals(@"T:\Same", StringComparison.OrdinalIgnoreCase)
            || c.Dir.Equals(@"t:\same", StringComparison.OrdinalIgnoreCase)));
        // 空白 ExeDir 不产生 exe 相对候选
        Assert.DoesNotContain(cands, c => c.Source == ToolchainService.SourceExeDir);
        Assert.DoesNotContain(cands, c => c.Source == ToolchainService.SourceExeTools);
        Assert.All(cands, c => Assert.False(string.IsNullOrWhiteSpace(c.Dir)));
    }

    // ---- 可执行文件匹配 ----

    [Fact]
    public void ResolveExe_acceptsTheWindowsExtension()
    {
        using var tmp = new TempDir();
        string exe = tmp.Touch("adb.exe");

        // 传进去的是不带扩展名的基名：调用方不该关心 .exe / .cmd 的差异。
        Assert.Equal(exe, ToolchainService.ResolveExe(tmp.Combine("adb")));
        Assert.Null(ToolchainService.ResolveExe(tmp.Combine("nope")));
    }

    [Fact]
    public void HasAdbAndHasScrcpy_checkTheGivenDirectoryOnly()
    {
        using var tmp = new TempDir();
        string tools = Path.Combine(tmp.Path, "tools");
        Directory.CreateDirectory(tools);
        File.WriteAllText(Path.Combine(tools, "adb.exe"), "x");

        Assert.True(ToolchainService.HasAdb(tools));
        Assert.False(ToolchainService.HasScrcpy(tools));
        Assert.False(ToolchainService.HasAdb(Path.Combine(tmp.Path, "empty")));
    }

    [Fact]
    public void LookPath_findsTheFirstHitInPath()
    {
        using var hit = new TempDir();
        using var other = new TempDir();
        string exe = hit.Touch("adb.exe");

        using (Env.Set("PATH", other.Path + Path.PathSeparator + hit.Path))
        {
            Assert.Equal(exe, ToolchainService.LookPath("adb"));
            Assert.Null(ToolchainService.LookPath("definitely-not-here"));
        }

        using (Env.Set("PATH", string.Empty))
        {
            Assert.Null(ToolchainService.LookPath("adb"));
        }
    }

    // ---- Resolve：整条链的优先级 ----

    [Fact]
    public void Resolve_prefersTheManualOverride()
    {
        using var tmp = new TempDir();
        string dir = EnsureDir(Path.Combine(tmp.Path, "manual"));
        File.WriteAllText(Path.Combine(dir, "adb.exe"), "x");
        File.WriteAllText(Path.Combine(dir, "scrcpy.exe"), "x");

        ToolchainSnapshot t = ToolchainService.Resolve(new ResolveOptions
        {
            EnvDir = dir,
            ConfigDir = Path.Combine(tmp.Path, "cfg"),
            ExeDir = Path.Combine(tmp.Path, "app"),
            AllowScan = false,
        });

        Assert.True(t.AdbResolved);
        Assert.Equal(ToolchainService.SourceOverride, t.AdbSource);
        Assert.Equal(dir, t.ToolDir);
        // adb 与 scrcpy 同目录 = 一份完整发行包，工作目录就用它
        Assert.True(t.ScrcpyResolved);
        Assert.Equal(dir, t.ScrcpyDir);
        Assert.Equal(dir, t.WorkDir);
    }

    [Fact]
    public void Resolve_remembersConfigDirAheadOfTheExeSide()
    {
        using var tmp = new TempDir();
        string cfg = EnsureDir(Path.Combine(tmp.Path, "cfg"));
        string exeTools = EnsureDir(Path.Combine(tmp.Path, "app", "tools"));
        File.WriteAllText(Path.Combine(cfg, "adb.exe"), "x");
        File.WriteAllText(Path.Combine(exeTools, "adb.exe"), "x");

        ToolchainSnapshot t = ToolchainService.Resolve(new ResolveOptions
        {
            ConfigDir = cfg,
            ExeDir = Path.Combine(tmp.Path, "app"),
            AllowScan = false,
        });

        Assert.Equal(ToolchainService.SourceConfig, t.AdbSource);
        Assert.Equal(cfg, t.ToolDir);
    }

    [Fact]
    public void Resolve_canTakeScrcpyFromADifferentDirectoryThanAdb()
    {
        using var tmp = new TempDir();
        string exeDir = EnsureDir(Path.Combine(tmp.Path, "app"));
        string tools = EnsureDir(Path.Combine(exeDir, "tools"));
        string rel = EnsureDir(Path.Combine(tmp.Path, "scrcpy"));
        File.WriteAllText(Path.Combine(tools, "adb.exe"), "x");
        File.WriteAllText(Path.Combine(rel, "scrcpy.exe"), "x");

        ToolchainSnapshot t = ToolchainService.Resolve(new ResolveOptions
        {
            ExeDir = exeDir,
            AllowScan = false,
        });

        Assert.Equal(ToolchainService.SourceExeTools, t.AdbSource);
        Assert.Equal(tools, t.ToolDir);
        Assert.True(t.ScrcpyResolved);
        // exe 相对候选里带 ".."，比较前先归一化（返回值原样带 ".." 是有意的：它只用于拼路径）
        Assert.Equal(Path.GetFullPath(rel), Path.GetFullPath(t.ScrcpyDir));
        // 工作目录跟 scrcpy 走：它要在旁边找 scrcpy-server 和依赖 dll。
        Assert.Equal(Path.GetFullPath(rel), Path.GetFullPath(t.WorkDir));
    }

    [Fact]
    public void Resolve_withNothingFound_reportsUnresolvedAndStillGivesADisplayDir()
    {
        using var tmp = new TempDir();
        string exeDir = EnsureDir(Path.Combine(tmp.Path, "app"));
        var o = new ResolveOptions { ExeDir = exeDir, AllowScan = false };

        using (Env.Set("PATH", Path.Combine(tmp.Path, "not-on-path")))
        {
            // 前置条件：这台机器的"常见安装位置"里真有 adb 时，"全落空"这条路走不到，
            // 用例就没有意义（开发机上装了 Android Studio 就会这样），直接跳过。
            if (ToolchainService.BuildCandidates(o).Any(c => ToolchainService.HasAdb(c.Dir))) return;

            ToolchainSnapshot t = ToolchainService.Resolve(o);

            Assert.False(t.AdbResolved);
            Assert.Equal(ToolchainService.SourceNone, t.AdbSource);
            Assert.False(t.ScrcpyResolved);
            // 没找到也要给个目录，界面那句"往这里放 adb.exe"才有落点。
            Assert.Equal(Path.Combine(exeDir, "tools"), t.ToolDir);
        }
    }

    [Fact]
    public void Resolve_usesPathWhenNoCandidateDirectoryHasIt()
    {
        using var tmp = new TempDir();
        string pathDir = EnsureDir(Path.Combine(tmp.Path, "bin"));
        File.WriteAllText(Path.Combine(pathDir, "adb.exe"), "x");
        File.WriteAllText(Path.Combine(pathDir, "scrcpy.exe"), "x");
        var o = new ResolveOptions
        {
            ExeDir = EnsureDir(Path.Combine(tmp.Path, "app")),
            AllowScan = false,
        };

        using (Env.Set("PATH", pathDir))
        {
            // 同上：候选目录里先有一个真的 adb，PATH 这一档就轮不到，跳过。
            if (ToolchainService.BuildCandidates(o).Any(c => ToolchainService.HasAdb(c.Dir))) return;

            ToolchainSnapshot t = ToolchainService.Resolve(o);

            Assert.True(t.AdbResolved);
            Assert.Equal(ToolchainService.SourcePath, t.AdbSource);
        }
    }

    // ---- 受限深度搜索 ----

    [Fact]
    public void Search_findsNamedDirsUpToTheDepthBudget()
    {
        using var tmp = new TempDir();
        string shallow = EnsureDir(Path.Combine(tmp.Path, "platform-tools"));
        string deep = EnsureDir(Path.Combine(tmp.Path, "Flash", "tools", "scrcpy"));
        // 第 4 层：超出预算（相对盘根只走 3 层），故意放个 adb.exe 验证它不被收进来
        string tooDeep = EnsureDir(Path.Combine(tmp.Path, "a", "b", "c", "platform-tools"));

        foreach (string d in new[] { shallow, deep, tooDeep })
        {
            File.WriteAllText(Path.Combine(d, "adb.exe"), "x");
        }

        List<string> hits = ToolchainService.Search(TimeSpan.FromSeconds(20), new[] { tmp.Path });

        Assert.Contains(shallow, hits);
        Assert.Contains(deep, hits);
        Assert.DoesNotContain(tooDeep, hits);
    }

    [Fact]
    public void Search_requiresTheDirectoryNameToMatchExactly_andSkipsSystemDirs()
    {
        using var tmp = new TempDir();
        // 名字里带 adb 但不是 platform-tools / scrcpy：旧探针就是在这里把 WinSxS 当成候选的
        string near = EnsureDir(Path.Combine(tmp.Path, "myadbtools"));
        string underWindows = EnsureDir(Path.Combine(tmp.Path, "Windows", "platform-tools"));
        File.WriteAllText(Path.Combine(near, "adb.exe"), "x");
        File.WriteAllText(Path.Combine(underWindows, "adb.exe"), "x");
        // 名字对但没有 adb.exe：也不能算命中
        EnsureDir(Path.Combine(tmp.Path, "scrcpy"));

        List<string> hits = ToolchainService.Search(TimeSpan.FromSeconds(20), new[] { tmp.Path });

        Assert.DoesNotContain(near, hits);
        Assert.DoesNotContain(underWindows, hits);
        Assert.Empty(hits);
    }

    [Fact]
    public void Search_withNoRoots_returnsEmptyFast() =>
        Assert.Empty(ToolchainService.Search(TimeSpan.FromSeconds(1), Array.Empty<string>()));

    [Theory]
    [InlineData("windows", true)]
    [InlineData("Windows", true)]          // 大小写不敏感
    [InlineData("$recycle.bin", true)]
    [InlineData("node_modules", true)]
    [InlineData("library", false)]         // 显式放行：macOS 的 ~/Library 要进
    [InlineData("Flash", false)]
    public void IsSkipped_usesTheExplicitDictionary(string name, bool want) =>
        Assert.Equal(want, ToolchainService.IsSkipped(name));

    [Fact]
    public void IsRealDir_rejectsMissingPaths()
    {
        using var tmp = new TempDir();
        Assert.True(ToolchainService.IsRealDir(tmp.Path));
        Assert.False(ToolchainService.IsRealDir(Path.Combine(tmp.Path, "nope")));
    }

    [Fact]
    public void RankHits_putsCompletePackagesFirstEvenWhenDeeper()
    {
        using var tmp = new TempDir();
        string adbOnly = EnsureDir(Path.Combine(tmp.Path, "platform-tools"));
        string complete = EnsureDir(Path.Combine(tmp.Path, "x", "y", "z", "scrcpy"));
        File.WriteAllText(Path.Combine(adbOnly, "adb.exe"), "x");
        File.WriteAllText(Path.Combine(complete, "adb.exe"), "x");
        File.WriteAllText(Path.Combine(complete, "scrcpy.exe"), "x");

        // 传入顺序故意把 adbOnly 放前面：排序必须把它挪到后面
        List<string> ranked = ToolchainService.RankHits(new List<string> { adbOnly, complete });

        Assert.Equal(complete, ranked[0]);
        Assert.Equal(adbOnly, ranked[1]);
        Assert.Equal(complete, ToolchainService.PickBest(ranked));
        Assert.Equal(string.Empty, ToolchainService.PickBest(new List<string>()));
    }

    [Fact]
    public void SourceLabel_coversEverySourceTheResolverCanReturn()
    {
        Assert.Equal("指定目录（-tools / SCRCPY_TOOL_DIR）", ToolchainService.SourceLabel(ToolchainService.SourceOverride));
        Assert.Equal("已保存目录", ToolchainService.SourceLabel(ToolchainService.SourceConfig));
        Assert.Equal("exe 同级 tools", ToolchainService.SourceLabel(ToolchainService.SourceExeTools));
        Assert.Equal("PATH", ToolchainService.SourceLabel(ToolchainService.SourcePath));
        Assert.Equal("自动搜索", ToolchainService.SourceLabel(ToolchainService.SourceScan));
        Assert.Equal("未找到", ToolchainService.SourceLabel(ToolchainService.SourceNone));
        // 未知来源不能抛异常，界面拿它当"未找到"显示
        Assert.Equal("未找到", ToolchainService.SourceLabel("something-new"));
    }

    [Fact]
    public void MissingHint_isWindowsOnly_andNamesNoMacPaths()
    {
        // 这份文案是 Windows 专用：不能出现 brew，也不能让 Windows 用户去找 .app
        string hint = ToolchainService.MissingHint;
        Assert.False(hint.Contains("brew", StringComparison.OrdinalIgnoreCase));
        Assert.False(hint.Contains(".app", StringComparison.Ordinal));
        Assert.True(hint.Contains("adb.exe", StringComparison.Ordinal));
        Assert.True(hint.Contains("SCRCPY_TOOL_DIR", StringComparison.Ordinal));
        Assert.True(hint.Contains("自动搜索", StringComparison.Ordinal));
    }

    private static string EnsureDir(string path)
    {
        Directory.CreateDirectory(path);
        return path;
    }
}
