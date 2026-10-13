using System.Windows;
using System.Windows.Controls;

namespace ScrcpyPicker.Views;

/// <summary>
/// 单行输入对话框（设置备注名用）。
///
/// WPF 没有内置 InputBox，而 .NET 8 上的 Microsoft.VisualBasic.Interaction 又依赖 WinForms，
/// 所以这里自己拼一个最小的：Enter 确定、Esc 取消，行为对齐旧前端的 prompt()——
/// 返回值要能区分"取消"和"清空"，所以走 TryShow 而不是直接给字符串。
/// </summary>
public sealed class InputDialog : Window
{
    private readonly TextBox _box;

    private InputDialog(string title, string prompt, string initial)
    {
        Title = title;
        SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        MinWidth = 380;

        _box = new TextBox
        {
            Text = initial,
            Margin = new Thickness(0, 8, 0, 0),
            MinWidth = 320,
        };

        var ok = new Button
        {
            Content = "确定",
            MinWidth = 88,
            IsDefault = true,   // Enter
            Margin = new Thickness(0, 0, 8, 0),
        };
        var cancel = new Button
        {
            Content = "取消",
            MinWidth = 88,
            IsCancel = true,    // Esc
        };
        ok.Click += (_, _) =>
        {
            DialogResult = true;
            Close();
        };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 14, 0, 0),
        };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);

        var body = new StackPanel { Margin = new Thickness(16) };
        body.Children.Add(new TextBlock { Text = prompt });
        body.Children.Add(_box);
        body.Children.Add(buttons);
        Content = body;

        Loaded += (_, _) =>
        {
            _box.Focus();
            _box.SelectAll();
        };
    }

    /// <summary>弹出并等待结果；取消返回 false，确定时把输入框内容（可能为空=清除）给出去。</summary>
    public static bool TryShow(Window owner, string title, string prompt, string initial, out string value)
    {
        var dlg = new InputDialog(title, prompt, initial) { Owner = owner };
        bool? result = dlg.ShowDialog();
        value = dlg._box.Text;
        return result == true;
    }
}
