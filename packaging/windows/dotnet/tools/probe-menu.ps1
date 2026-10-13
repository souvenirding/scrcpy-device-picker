# probe-menu.ps1 - find out where WPF puts the DataGrid row ContextMenu.
#
# The smoke harness right-clicks a real device row and then looks for MenuItems among the
# desktop's top-level children of that process. It found none, so this probe dumps *every*
# UIA window of the process, in both the control view and the raw view, before and after the
# click, and additionally asks Win32 for the visible top-level windows of that pid.
# Diffing the two dumps tells us whether the popup is (a) not opening at all, (b) a child of
# the main window in the UIA tree, or (c) reachable only through the raw view.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File probe-menu.ps1 -Exe <exe>

[CmdletBinding()]
param(
    [string]$Exe = '',
    [int]$RowTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
[void][System.Windows.Automation.AutomationElement]::RootElement

Add-Type -Namespace Probe -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
[DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
public static System.Collections.Generic.List<string> TopWindows(uint wantPid) {
    var list = new System.Collections.Generic.List<string>();
    EnumWindowsProc cb = (h, l) => {
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (pid == wantPid) {
            var sb = new System.Text.StringBuilder(256);
            GetClassName(h, sb, 256);
            list.Add((IsWindowVisible(h) ? "vis" : "hid") + " class=" + sb + " text=" + GetWindowTextLength(h));
        }
        return true;
    };
    EnumWindows(cb, IntPtr.Zero);
    return list;
}
'@
[void][Probe.Win]::SetProcessDPIAware()

function Walk($node, $tw, $depth, $lines, $limit) {
    if ($lines.Count -ge $limit) { return }
    $child = $tw.GetFirstChild($node)
    while ($null -ne $child) {
        $ct = ''; $cn = ''; $cls = ''; $name = ''; $pid2 = -1; $r = ''
        try { $ct = $child.Current.ControlType.ProgrammaticName } catch { }
        try { $cn = $child.Current.Name } catch { }
        try { $cls = $child.Current.ClassName } catch { }
        try { $pid2 = $child.Current.ProcessId } catch { }
        try { $b = $child.Current.BoundingRectangle; $r = ('{0},{1} {2}x{3}' -f $b.X, $b.Y, $b.Width, $b.Height) } catch { }
        [void]$lines.Add(('  ' * $depth) + $ct + ' cls=[' + $cls + '] pid=' + $pid2 + ' rect=' + $r + ' name=[' + $cn + ']')
        Walk $child $tw ($depth + 1) $lines $limit
        $child = $tw.GetNextSibling($child)
    }
}

function Dump-Tree($label, $root, $procId, $lines) {
    [void]$lines.Add('=== ' + $label + ' : control view under main window ===')
    Walk $root ([System.Windows.Automation.TreeWalker]::ControlViewWalker) 1 $lines 400
    [void]$lines.Add('=== ' + $label + ' : raw view of desktop children with this pid ===')
    $tw = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $child = $tw.GetFirstChild([System.Windows.Automation.AutomationElement]::RootElement)
    while ($null -ne $child) {
        $p = -1
        try { $p = $child.Current.ProcessId } catch { }
        if ($p -eq $procId) {
            $cls = ''; $ct = ''; $name = ''
            try { $cls = $child.Current.ClassName } catch { }
            try { $ct = $child.Current.ControlType.ProgrammaticName } catch { }
            try { $name = $child.Current.Name } catch { }
            [void]$lines.Add('win ' + $ct + ' cls=[' + $cls + '] name=[' + $name + ']')
            Walk $child ([System.Windows.Automation.TreeWalker]::RawViewWalker) 1 $lines 100000
        }
        $child = $tw.GetNextSibling($child)
    }
    [void]$lines.Add('=== ' + $label + ' : win32 top-level windows of pid ===')
    foreach ($w in [Probe.Win]::TopWindows([uint32]$procId)) { [void]$lines.Add('  ' + $w) }
}

if (-not $Exe) { $Exe = Join-Path (Split-Path $PSScriptRoot -Parent) 'Dist\ScrcpyPicker.exe' }
if (-not (Test-Path $Exe)) { throw "no exe at $Exe" }
$exeDir = Split-Path $Exe -Parent
$cfg = Join-Path $env:TEMP ('probe-menu-cfg-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
$origCfg = $env:SCRCPY_CONFIG_DIR
$handle = [IntPtr]::Zero
try {
    $env:SCRCPY_CONFIG_DIR = $cfg
    $p = Start-Process -FilePath $Exe -ArgumentList @('-no-scan') -PassThru -WorkingDirectory $exeDir
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $p.Refresh()
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $handle = $p.MainWindowHandle; break }
    }
    if ($handle -eq [IntPtr]::Zero) { throw 'no main window' }
    Write-Host ('pid=' + $p.Id + ' hwnd=' + $handle)

    $row = $null
    for ($i = 0; $i -lt ($RowTimeoutSeconds / 3); $i++) {
        Start-Sleep -Seconds 3
        $lines = New-Object System.Collections.Generic.List[string]
        Walk ([System.Windows.Automation.AutomationElement]::FromHandle($handle)) ([System.Windows.Automation.TreeWalker]::ControlViewWalker) 0 $lines 400
        $hit = @($lines | Where-Object { $_ -match 'ControlType.DataItem' })
        Write-Host ('poll ' + $i + ' dataitems=' + $hit.Count)
        if ($hit.Count -gt 0) {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            $all = New-Object System.Collections.Generic.List[object]
            # re-walk to get the element itself
            $tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker
            $queue = New-Object System.Collections.Generic.Queue[object]
            $queue.Enqueue($root)
            while ($queue.Count -gt 0) {
                $n = $queue.Dequeue()
                $c = $tw.GetFirstChild($n)
                while ($null -ne $c) { $all.Add($c); $queue.Enqueue($c); $c = $tw.GetNextSibling($c) }
            }
            $row = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.DataItem' })[0]
            break
        }
    }
    if ($null -eq $row) { throw 'no device row' }

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    $wr = $root.Current.BoundingRectangle
    $r = $row.Current.BoundingRectangle
    $cx = [int]([Math]::Max($r.X, $wr.X) + ([Math]::Min($r.X + $r.Width, $wr.X + $wr.Width) - [Math]::Max($r.X, $wr.X)) / 2)
    $cy = [int]($r.Y + $r.Height / 2)
    Write-Host ('window ' + $wr + ' row ' + $r + ' click ' + $cx + ',' + $cy)

    $before = New-Object System.Collections.Generic.List[string]
    Dump-Tree 'BEFORE' $root $p.Id $before
    [void][Probe.Win]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 600
    [Probe.Win]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 250
    [Probe.Win]::mouse_event(8, 0, 0, 0, [UIntPtr]::Zero)
    [Probe.Win]::mouse_event(16, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Seconds 3
    $after = New-Object System.Collections.Generic.List[string]
    Dump-Tree 'AFTER' ([System.Windows.Automation.AutomationElement]::FromHandle($handle)) $p.Id $after

    $out = Join-Path $env:TEMP 'probe-menu.txt'
    $all = New-Object System.Collections.Generic.List[string]
    $all.Add('### BEFORE'); $all.AddRange($before); $all.Add(''); $all.Add('### AFTER'); $all.AddRange($after)
    [IO.File]::WriteAllLines($out, $all, [Text.UTF8Encoding]::new($true))
    Write-Host ('wrote ' + $out)
    Write-Host ('before lines=' + $before.Count + ' after lines=' + $after.Count)
    Write-Host ('menuitems before=' + @($before | Where-Object { $_ -match 'ControlType.MenuItem' }).Count +
        ' after=' + @($after | Where-Object { $_ -match 'ControlType.MenuItem' }).Count)
    [void][Probe.Win]::PostMessage($handle, 0x10, [IntPtr]0, [IntPtr]0)
    $p.WaitForExit(6000) | Out-Null
    if (-not $p.HasExited) { $p.Kill() }
}
finally {
    if ($handle -ne [IntPtr]::Zero) { [void][Probe.Win]::PostMessage($handle, 0x10, [IntPtr]0, [IntPtr]0) }
    if ($origCfg) { $env:SCRCPY_CONFIG_DIR = $origCfg } else { Remove-Item Env:SCRCPY_CONFIG_DIR -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $cfg -Recurse -Force -ErrorAction SilentlyContinue
}
