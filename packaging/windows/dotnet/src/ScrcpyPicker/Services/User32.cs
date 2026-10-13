using System.Runtime.InteropServices;

namespace ScrcpyPicker.Services;

/// <summary>
/// 导航条跟随投屏窗口要用的那几个 user32 调用。
/// 只放声明，不放逻辑——逻辑在 <see cref="NavBarLayout"/>（那部分要能无头单测）。
/// </summary>
internal static class User32
{
    /// <summary>屏幕坐标：user32 一律是**物理像素**，给 WPF 用之前必须除以 DPI 缩放。</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
}
