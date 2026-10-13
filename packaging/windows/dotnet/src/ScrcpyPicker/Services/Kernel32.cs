using System.Runtime.InteropServices;
using System.Text;

namespace ScrcpyPicker.Services;

/// <summary>
/// 自动搜索与投屏存活判定要用的几个 Win32 调用。
/// 只声明用到的部分，不引 SDK 头文件，避免和 .NET 自带的 DriveInfo/Process 抢语义。
/// </summary>
internal static class Kernel32
{
    public enum DriveType : uint
    {
        Unknown = 0,
        Removed = 1,
        Removable = 2,
        Fixed = 3,
        Network = 4,
        Cdrom = 5,
        Ram = 6,
    }

    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const uint ProcessTerminate = 0x0001;
    public const uint StillActive = 259;

    [DllImport("kernel32.dll", SetLastError = false)]
    public static extern uint GetLogicalDrives();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
    public static extern DriveType GetDriveType(string rootPath);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetExitCodeProcess(IntPtr handle, out uint exitCode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool QueryFullProcessImageName(
        IntPtr handle, uint flags, StringBuilder exeName, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr handle, uint exitCode);
}
