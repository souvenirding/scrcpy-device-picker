using System.IO;

namespace ScrcpyPicker.Tests;

/// <summary>
/// 测试用临时目录：用完即删，绝不碰 %APPDATA%\ScrcpyPicker\devices.json。
/// </summary>
internal sealed class TempDir : IDisposable
{
    public string Path { get; }

    public TempDir()
    {
        Path = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            "picker-tests-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Path);
    }

    /// <summary>在临时目录里造一个文件（含中间目录），返回它的完整路径。</summary>
    public string Touch(string relative)
    {
        string full = System.IO.Path.Combine(Path, relative);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
        File.WriteAllText(full, "placeholder");
        return full;
    }

    public string Combine(params string[] parts) =>
        System.IO.Path.Combine(new[] { Path }.Concat(parts).ToArray());

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch { /* 测试收尾失败不算用例失败 */ }
    }
}

/// <summary>
/// 会改 PATH / SCRCPY_CONFIG_DIR 这类进程级环境变量的用例都归到这个集合，
/// xunit 对同一集合内串行执行，否则两个用例互相踩对方的 PATH。
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public class EnvCollectionDefinition : ICollectionFixture<object>
{
    public const string Name = "env";
}

/// <summary>环境变量读写的小工具：保证异常路径也能恢复原值。</summary>
internal static class Env
{
    public static IDisposable Set(string name, string? value) => new Scope(name, value);

    private sealed class Scope : IDisposable
    {
        private readonly string _name;
        private readonly string? _before;

        public Scope(string name, string? value)
        {
            _name = name;
            _before = Environment.GetEnvironmentVariable(name);
            Environment.SetEnvironmentVariable(name, value);
        }

        public void Dispose() => Environment.SetEnvironmentVariable(_name, _before);
    }
}
