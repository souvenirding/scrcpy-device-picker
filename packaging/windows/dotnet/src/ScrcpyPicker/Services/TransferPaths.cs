using System.IO;
using Microsoft.Win32;

namespace ScrcpyPicker.Services;

/// <summary>
/// 拉取落地的「下载」目录。优先读用户外壳文件夹（OneDrive 重定向也认），
/// 读不到再退回 %USERPROFILE%\Downloads；测试/排障可用 SCRCPY_DOWNLOAD_DIR 覆盖。
/// </summary>
public static class TransferPaths
{
    /// <summary>Windows「下载」known folder 的 GUID。</summary>
    private const string DownloadsGuid = "{374DE290-123F-4565-9164-39C4925E467B}";

    public static string DownloadsDirectory()
    {
        string? overrideDir = Environment.GetEnvironmentVariable("SCRCPY_DOWNLOAD_DIR");
        if (!string.IsNullOrWhiteSpace(overrideDir))
        {
            EnsureDirectory(overrideDir);
            return overrideDir;
        }

        string? fromShell = ReadUserShellFolder(DownloadsGuid);
        if (fromShell is not null && Directory.Exists(fromShell)) return fromShell;

        string fallback = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        EnsureDirectory(fallback);
        return fallback;
    }

    /// <summary>读 HKCU 的 User Shell Folders 值并展开 %USERPROFILE% 之类的变量。</summary>
    private static string? ReadUserShellFolder(string guid)
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders");
            if (key?.GetValue(guid) is not string raw || raw.Length == 0) return null;
            return Environment.ExpandEnvironmentVariables(raw);
        }
        catch
        {
            return null;
        }
    }

    private static void EnsureDirectory(string dir)
    {
        try { Directory.CreateDirectory(dir); } catch { /* 写不进去时让 adb 自己报错 */ }
    }
}
