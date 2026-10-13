using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace ScrcpyPicker.Views;

/// <summary>
/// bool -> Visibility。ConverterParameter 传 "invert" 时取反。
/// 右键菜单要按行状态决定哪些项出现（离线行不给投屏和按键），
/// 用这一个转换器就够，不再为每个组合写第二个类。
/// </summary>
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        bool flag = value is bool b && b;
        bool invert = (parameter as string)?.Equals("invert", StringComparison.OrdinalIgnoreCase) == true;
        if (invert) flag = !flag;
        return flag ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>字符串非空 -> Visibility（工具面板里的候选提示用）。</summary>
public sealed class NonEmptyToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => string.IsNullOrEmpty(value as string) ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
