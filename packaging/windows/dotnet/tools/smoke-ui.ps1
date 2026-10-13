# smoke-ui.ps1 - drive the real WPF window through UI Automation, twice, and screenshot both.
#
# Design notes
#   * ASCII-only source. Nothing Chinese is hardcoded: element identity comes from the
#     AutomationProperties.AutomationId values declared in MainWindow.xaml, and column
#     captions are read out of that same file at run time, so the assertions cannot
#     drift away from the UI.
#   * Two scenarios are run against the same exe:
#       Healthy      - adb + scrcpy resolve; the tool panel and the banner must be hidden
#       MissingTools - PATH stripped + -no-scan; banner must open and the tool panel
#                      (input box, save / scan / clear buttons) must become visible
#     That second run is the only cheap way to prove the conditional panels actually work.
#     It runs from a throw-away copy of the exe in an empty directory: the shipped
#     Dist\ScrcpyPicker.exe has Dist\tools next to it, and that candidate outranks PATH,
#     so stripping PATH would not produce a "no tools" state at all.
#   * A third run, Offline, seeds devices.json with a device that is not connected and
#     checks the cached/offline branch: grey row, remembered address, reduced context menu.
#     It needs no hardware either.
#   * A real device is not required. When one is attached the grid gets rows, and those
#     rows are asserted only if -ExpectDevice is passed (otherwise the run stays usable
#     on a machine with nothing plugged in).
#   * The config dir is a fresh temp folder per run, so a smoke run never touches the
#     real %APPDATA%\ScrcpyPicker\devices.json.
#
# Usage
#   powershell -NoProfile -ExecutionPolicy Bypass -File smoke-ui.ps1 `
#     -Exe C:\path\ScrcpyPicker.exe [-Xaml path\MainWindow.xaml] `
#     [-Scenario Healthy|MissingTools|Offline|Device|Both] [-OutDir dir] [-ExpectDevice]
#   -ExpectDevice adds the on-bench run (right-click menu + double-click cast); pass
#     -Scenario Device to run only that one.

[CmdletBinding()]
param(
    [string]$Exe = '',
    [string]$Xaml = '',
    [string]$OutDir = '',
    [string]$Scenario = 'Both',
    [switch]$ExpectDevice,
    [string]$CodeBehind = '',
    [int]$SettleSeconds = 20,
    [int]$AfterClickSeconds = 12
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host ('[smoke] ' + $m) }

# Read every value of a repeating XAML attribute (captions / automation ids).
function Get-XamlValue([string]$file, [string]$pattern) {
    $text = [IO.File]::ReadAllText($file)
    $out = @()
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $v = $m.Groups[1].Value.Trim()
        if ($v -and $v.IndexOf('{') -lt 0) { $out += $v }
    }
    return , $out
}

# Breadth-first UIA walk.
#
# Why not FindAll: under PowerShell 5.1 the static field
# [System.Windows.Automation.AutomationElement]::TrueCondition binds to $null, and
# FindAll then throws "value cannot be null (parameter 'condition')" (measured with
# probe-uia.ps1). TreeWalker + ControlViewWalker needs no condition at all.
function Get-UiaDescendants($node) {
    $tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $out = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($node)
    while ($queue.Count -gt 0 -and $out.Count -lt 3000) {
        $cur = $queue.Dequeue()
        $child = $tw.GetFirstChild($cur)
        while ($null -ne $child) {
            $out.Add($child)
            $queue.Enqueue($child)
            $child = $tw.GetNextSibling($child)
        }
    }
    return , $out
}

if (-not $Exe) { throw '-Exe is required' }
if (-not (Test-Path -LiteralPath $Exe)) { throw ('exe not found: ' + $Exe) }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$exeDir = [IO.Path]::GetDirectoryName($Exe)

if (-not $Xaml) {
    # bin\<cfg>\<tfm>\win-x64 -> four levels up is the project root
    $Xaml = (Resolve-Path -LiteralPath (Join-Path $exeDir '..\..\..\..\Views\MainWindow.xaml')).Path
}
if (-not (Test-Path -LiteralPath $Xaml)) { throw ('xaml not found: ' + $Xaml) }
$Xaml = (Resolve-Path -LiteralPath $Xaml).Path

if (-not $OutDir) { $OutDir = Join-Path $exeDir 'smoke' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace Smoke -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@
[void][Smoke.Win]::SetProcessDPIAware()

# --- the element contract -----------------------------------------------------
# always on screen
$Core = @('btnRefresh', 'btnDeepRefresh', 'swtUsbFirst', 'lblStatusLine', 'dgDevices', 'lblFooter')
# only on screen when adb / scrcpy could not be resolved.
#
# Note what is NOT here: 'toolPanel' (ui:Card) and 'bannerInfo' (ui:InfoBar) themselves
# never appear in the UIA control view - those two controls are decorative containers whose
# AutomationId lives on the peer but is not surfaced as a separate element (verified against
# uitree-MissingTools.txt). Their children are, so the children are the contract:
#   toolDirInput / btnToolApply / btnToolScan / btnToolClear -> the card body
#   'CloseButton'                                            -> the InfoBar's own close button,
#       which only exists while IsOpen is true. It is the observable proxy for the banner.
$ToolPanel = @('toolDirInput', 'btnToolApply', 'btnToolScan', 'btnToolClear')
$BannerId = 'CloseButton'

$Headers = Get-XamlValue $Xaml 'Header="([^"]+)"'
Write-Step ('xaml ' + $Xaml + ' headers=' + $Headers.Count)
if (-not $Headers.Count) { throw 'no column headers parsed from xaml - the markup or the regex changed' }

# Right-click menu captions come from the code-behind, not the xaml (the menu is built per
# row). Lines guarded by "if (item.Something)" only appear for some devices, so they are
# excluded from the must-exist list.
if (-not $CodeBehind) { $CodeBehind = Join-Path ([IO.Path]::GetDirectoryName($Xaml)) 'MainWindow.xaml.cs' }
if (-not (Test-Path -LiteralPath $CodeBehind)) { throw ('code-behind not found: ' + $CodeBehind) }
$CsText = [IO.File]::ReadAllText($CodeBehind)
$AllMenu = @([regex]::Matches($CsText, 'Add\(menu,\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$CondMenu = @([regex]::Matches($CsText, 'if\s*\(item\.\w+\)\s*Add\(menu,\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$AlwaysMenu = @($AllMenu | Where-Object { $CondMenu -notcontains $_ })
Write-Step ('menu captions=' + $AllMenu.Count + ' unconditional=' + $AlwaysMenu.Count + ' conditional=' + $CondMenu.Count)
if (-not $AlwaysMenu.Count) { throw 'no menu captions parsed from the code-behind - the markup or the regex changed' }

# --- navigation bar contract --------------------------------------------------
# The docked key strip lives in NavBarWindow.xaml. Its automation ids and the Android
# keyevent codes are read from that file, so renaming a button or re-pointing a code
# fails this harness loudly instead of silently breaking the feature.
function Fmt-Rect($r) {
    return ([int]$r.X).ToString() + ',' + ([int]$r.Y).ToString() + ' ' +
        ([int]$r.Width).ToString() + 'x' + ([int]$r.Height).ToString()
}

$NavXaml = Join-Path ([IO.Path]::GetDirectoryName($Xaml)) 'NavBarWindow.xaml'
if (-not (Test-Path -LiteralPath $NavXaml)) { throw ('nav bar markup not found: ' + $NavXaml) }
# Get-XamlValue returns with a leading comma on purpose, so assigning it *without* an
# @() wrapper is what unrolls it into a flat list (wrapping it here would hand back one
# element that happens to be the whole array - the same trap $Headers above avoids).
$NavIds = @(Get-XamlValue $NavXaml 'AutomationProperties\.AutomationId="(btnNav[A-Za-z]+)"' | ForEach-Object { $_ })
$NavCodes = @([regex]::Matches([IO.File]::ReadAllText($NavXaml), 'Tag="(\d+)"') | ForEach-Object { $_.Groups[1].Value })
$WantedCodes = @('4', '3', '187', '25', '24', '223', '224')   # back home recents vold volu sleep wake
Write-Step ('nav buttons=' + $NavIds.Count + ' codes=' + ($NavCodes -join '/'))
if ($NavIds.Count -lt 8) { throw ('expected 7 key buttons + close in the nav bar, parsed ' + $NavIds.Count) }
if ($NavCodes.Count -ne ($NavIds.Count - 1)) { throw 'every nav button except the close box must carry a keyevent code' }
foreach ($c in $WantedCodes) { if ($NavCodes -notcontains $c) { throw ('the nav bar lost keyevent code ' + $c) } }
$NavMarker = $NavIds[0]

# Which captions does an *offline* row get? Everything outside the
# "if (!item.IsOffline) { ... }" block. Rather than hardcode the three strings (this file is
# ASCII-only and they are Chinese), the block is located by brace counting and the Add(menu,
# ...) calls are bucketed by whether their line falls inside it.
function Split-GatedMenuCaptions([string]$text) {
    $lines = $text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'if\s*\(\s*!item\.IsOffline\s*\)') { $start = $i; break }
    }
    if ($start -lt 0) { throw 'the context menu is no longer gated on !item.IsOffline - update this harness' }
    # The opening brace may sit on the guard line or on its own line (Allman style here),
    # so start counting at the first line that actually opens one.
    $depth = 0; $end = -1; $opened = $false
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $opens = ([regex]::Matches($lines[$i], '\{')).Count
        $closes = ([regex]::Matches($lines[$i], '\}')).Count
        if ($opens -gt 0) { $opened = $true }
        if (-not $opened) {
            if ($closes -gt 0) { throw 'the IsOffline guard has no block to find' }
            continue
        }
        $depth += $opens
        $depth -= $closes
        if ($depth -le 0) { $end = $i; break }
    }
    if ($end -lt 0) { throw 'unbalanced braces after the IsOffline guard' }
    $gated = @(); $ungated = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], 'Add\(menu,\s*"([^"]+)"')) {
            if ($i -gt $start -and $i -lt $end) { $gated += $m.Groups[1].Value }
            else { $ungated += $m.Groups[1].Value }
        }
    }
    # single pscustomobject on purpose: two arrays would be flattened into one return value.
    return [pscustomobject]@{ Gated = $gated; Ungated = $ungated }
}
$MenuSplit = Split-GatedMenuCaptions $CsText
Write-Step ('offline-gated captions=' + $MenuSplit.Gated.Count + ' always-present=' + $MenuSplit.Ungated.Count)
if ($MenuSplit.Ungated.Count -lt 2) { throw 'the offline branch of the context menu looks empty - re-check the harness' }

# The row status column shows one of two captions (online / offline, in Chinese); both come
# from the view model, so read them out of
# the source instead of typing them here.
$StateSrc = Join-Path (Split-Path -Parent $CodeBehind) '..\ViewModels\DeviceItem.cs'
if (-not (Test-Path -LiteralPath $StateSrc)) { throw ('view model not found: ' + $StateSrc) }
$VmText = [IO.File]::ReadAllText($StateSrc)
$m = [regex]::Match($VmText, 'IsOffline\s*\?\s*"([^"]+)"\s*:\s*"([^"]+)"')
if (-not $m.Success) { throw 'cannot read the online/offline captions out of DeviceItem.cs' }
$OfflineText = $m.Groups[1].Value
$OnlineText = $m.Groups[2].Value
Write-Step ('state captions parsed from ' + (Split-Path -Leaf $StateSrc))

# --- one run ------------------------------------------------------------------
function Invoke-Scenario {
    param([string]$Name, [bool]$StripPath, [string[]]$ExeArgs, [switch]$ToolsFree)

    Write-Step ('=== scenario ' + $Name + ' ===')
    $fail = @()
    $dump = New-Object System.Collections.Generic.List[string]
    $handle = [IntPtr]::Zero

    $cfg = Join-Path $env:TEMP ('picker-smoke-cfg-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null

    # The app looks for a tools folder next to the running exe, so a scenario that wants
    # "no toolchain anywhere" has to run a copy that sits alone in an empty directory.
    $runExe = $Exe
    $runDir = $exeDir
    $sandbox = $null
    if ($ToolsFree) {
        $sandbox = Join-Path $env:TEMP ('picker-smoke-bin-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
        $runExe = Join-Path $sandbox (Split-Path -Leaf $Exe)
        Copy-Item -LiteralPath $Exe -Destination $runExe
        $runDir = $sandbox
        Write-Step ('tools-free copy ' + $runExe)
    }

    # remember and restore: this shell is the developer's own session
    $origPath = $env:PATH
    $origCfg = $env:SCRCPY_CONFIG_DIR
    $origToolDir = $env:SCRCPY_TOOL_DIR
    $p = $null
    try {
        $env:SCRCPY_CONFIG_DIR = $cfg
        Remove-Item Env:SCRCPY_TOOL_DIR -ErrorAction SilentlyContinue
        if ($StripPath) {
            # Windows system dirs only: no adb on PATH, and -no-scan stops the drive walk.
            $env:PATH = 'C:\Windows\system32;C:\Windows'
        }
        # Start-Process rejects an empty -ArgumentList, so only pass it when there is one.
        if ($ExeArgs -and $ExeArgs.Count) {
            $p = Start-Process -FilePath $runExe -ArgumentList $ExeArgs -PassThru -WorkingDirectory $runDir
        } else {
            $p = Start-Process -FilePath $runExe -PassThru -WorkingDirectory $runDir
        }
        Write-Step ('pid=' + $p.Id + ' cfg=' + $cfg)

        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            $p.Refresh()
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $handle = $p.MainWindowHandle; break }
        }
        if ($handle -eq [IntPtr]::Zero) { throw 'main window never appeared' }
        Write-Step ('hwnd=' + $handle)

        Start-Sleep -Seconds $SettleSeconds

        $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $all = Get-UiaDescendants $root

        $dump.Add('scenario=' + $Name)
        $dump.Add('window name=' + $root.Current.Name + ' class=' + $root.Current.ClassName)
        $dump.Add('descendants=' + $all.Count)

        $byId = @{}
        $byName = @{}
        foreach ($e in $all) {
            $n = ''
            try { $n = $e.Current.Name } catch { $n = '<unreadable>' }
            $a = ''
            try { $a = $e.Current.AutomationId } catch { }
            $t = $e.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $dump.Add(('{0,-16} id={1,-14} enabled={2,-6} "{3}"' -f $t, $a, $e.Current.IsEnabled, $n))
            if ($a -and -not $byId.ContainsKey($a)) { $byId[$a] = $e }
            if ($n -and -not $byName.ContainsKey($n)) { $byName[$n] = $e }
        }

        if ($all.Count -lt 15) { $fail += ('ui tree too small: ' + $all.Count) }

        foreach ($id in $Core) {
            if (-not $byId.ContainsKey($id)) { $fail += ('missing element ' + $id) }
        }
        foreach ($id in $ToolPanel) {
            $present = $byId.ContainsKey($id)
            if ($StripPath -and -not $present) { $fail += ('tool panel element missing: ' + $id) }
            if (-not $StripPath -and $present) { $fail += ('tool panel element should be hidden: ' + $id) }
        }

        # banner: the InfoBar's close button is the only part of it UIA can see
        $bannerOpen = $byId.ContainsKey($BannerId)
        if ($StripPath -and -not $bannerOpen) { $fail += 'banner should be open when tools are missing' }
        if (-not $StripPath -and $bannerOpen) { $fail += 'banner should be closed when tools resolve' }

        # the status line must actually reflect the difference between the two runs:
        # resolved tools print "adb.exe", missing tools print a not-found phrase instead.
        $status = ''
        foreach ($e in $all) {
            try { if ($e.Current.AutomationId -eq 'lblStatusLine') { $status = $e.Current.Name; break } } catch { }
        }
        $dump.Add('statusLine=' + $status)
        if (-not $status) { $fail += 'status line is empty' }
        $resolved = $status.IndexOf('adb.exe', [StringComparison]::Ordinal) -ge 0
        if ($StripPath -and $resolved) { $fail += 'status line still claims adb.exe with PATH stripped' }
        if (-not $StripPath -and -not $resolved) { $fail += 'status line does not name a resolved adb.exe' }

        foreach ($h in $Headers) {
            if (-not $byName.ContainsKey($h)) { $fail += ('missing column header: ' + $h) }
        }

        # screenshot from the UIA rect (physical pixels)
        $r = $root.Current.BoundingRectangle
        $w = [int]$r.Width
        $h2 = [int]$r.Height
        if ($w -gt 10 -and $h2 -gt 10) {
            $bmp = New-Object System.Drawing.Bitmap($w, $h2)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, (New-Object System.Drawing.Size($w, $h2)))
            $png = Join-Path $OutDir ($Name + '.png')
            $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose(); $bmp.Dispose()
            Write-Step ('screenshot ' + $png + ' ' + $w + 'x' + $h2)
        } else {
            $fail += ('bad window rect: ' + $w + 'x' + $h2)
        }

        # press the refresh button through its command, then prove the app survived it
        if ($byId.ContainsKey('btnRefresh')) {
            $pattern = $null
            if ($byId['btnRefresh'].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
                $pattern.Invoke()
                Write-Step 'invoked btnRefresh'
            } else {
                $fail += 'btnRefresh is not invokable'
            }
        }

        Start-Sleep -Seconds $AfterClickSeconds
        $p.Refresh()
        if ($p.HasExited) { throw ('process exited after refresh, code=' + $p.ExitCode) }

        $root2 = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $all2 = Get-UiaDescendants $root2
        $dump.Add('')
        $dump.Add('--- after refresh: descendants=' + $all2.Count)
        foreach ($e in $all2) {
            $n = ''
            try { $n = $e.Current.Name } catch { $n = '<unreadable>' }
            $t = $e.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $a = ''
            try { $a = $e.Current.AutomationId } catch { }
            $dump.Add(('{0,-16} id={1,-14} enabled={2,-6} "{3}"' -f $t, $a, $e.Current.IsEnabled, $n))
        }

        # the footer is where the app prints its own summary; it must mention a count
        $footer = ''
        foreach ($e in $all2) {
            try { if ($e.Current.AutomationId -eq 'lblFooter') { $footer = $e.Current.Name; break } } catch { }
        }
        $dump.Add('footer=' + $footer)
        if (-not $footer) { $fail += 'footer text is empty - refresh never produced a summary' }

        # device rows. A real device is optional: without -ExpectDevice this only records
        # what the grid showed, so the same script still passes on an empty bench.
        $items = @($all2 | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.DataItem' })
        $cells = @($all2 | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Custom' })
        $dump.Add('rows=' + $items.Count + ' cells=' + $cells.Count + ' expectDevice=' + $ExpectDevice)
        Write-Step ('grid rows=' + $items.Count + ' cells=' + $cells.Count)
        if ($ExpectDevice -and -not $StripPath) {
            if ($items.Count -lt 1) { $fail += '-ExpectDevice was passed but the grid has no rows' }
            # every row must fill all the columns declared in the xaml; an empty cell means
            # the row template or the binding is broken, not that the device is missing.
            if ($items.Count -gt 0 -and $cells.Count -lt ($items.Count * $Headers.Count)) {
                $fail += ('grid has ' + $cells.Count + ' cells for ' + $items.Count + ' row(s), expected at least ' + ($items.Count * $Headers.Count))
            }
        }
    }
    catch {
        $fail += ('exception: ' + $_.Exception.Message)
        Write-Host $_.ScriptStackTrace
    }
    finally {
        if ($handle -ne [IntPtr]::Zero) {
            # WM_CLOSE: shut down through the app's own path (timer stop + OnExit).
            [void][Smoke.Win]::PostMessage($handle, 0x10, [IntPtr]0, [IntPtr]0)
        }
        if ($p) {
            $p.WaitForExit(8000) | Out-Null
            if (-not $p.HasExited) { Write-Step 'still alive after WM_CLOSE, killing'; $p.Kill() }
        }
        $env:PATH = $origPath
        if ($origCfg) { $env:SCRCPY_CONFIG_DIR = $origCfg } else { Remove-Item Env:SCRCPY_CONFIG_DIR -ErrorAction SilentlyContinue }
        if ($origToolDir) { $env:SCRCPY_TOOL_DIR = $origToolDir } else { Remove-Item Env:SCRCPY_TOOL_DIR -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $cfg -Recurse -Force -ErrorAction SilentlyContinue
        if ($sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

        $dumpPath = Join-Path $OutDir ('uitree-' + $Name + '.txt')
        [IO.File]::WriteAllLines($dumpPath, $dump, [Text.UTF8Encoding]::new($true))
        Write-Step ('uitree ' + $dumpPath)
    }

    foreach ($m in $fail) { Write-Host ('   X ' + $m) }
    return $fail.Count
}

# --- device-driven scenario ---------------------------------------------------
# Needs a real phone/tablet on the bench. Skipped unless -ExpectDevice is passed,
# because on a machine with nothing plugged in there is nothing to click.

function Click-At {
    param([int]$X, [int]$Y, [string]$Button = 'left', [int]$Clicks = 1)

    # The shell is DPI-aware (SetProcessDPIAware above) and UIA reports physical pixels,
    # so the coordinates go through untouched - but ask the OS where the cursor really
    # ended up: a point outside the virtual desktop gets clamped and the click then lands
    # on some other window, which is exactly the kind of failure that reads as "the app
    # is broken".
    [void][Smoke.Win]::SetCursorPos($X, $Y)
    $pt = New-Object Smoke.Win+POINT
    [void][Smoke.Win]::GetCursorPos([ref]$pt)
    Write-Step ('cursor ' + $X + ',' + $Y + ' -> ' + $pt.X + ',' + $pt.Y)
    Start-Sleep -Milliseconds 300
    $down = 2; $up = 4
    if ($Button -eq 'right') { $down = 8; $up = 16 }
    for ($i = 0; $i -lt $Clicks; $i++) {
        [Smoke.Win]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
        [Smoke.Win]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 120
    }
}

function Send-Escape {
    [Smoke.Win]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Smoke.Win]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
}

# Where does WPF put an open ContextMenu? Measured with probe-menu.ps1 against the real
# app: the right-click adds a fresh visible top-level HWND of class
# "HwndWrapper[ScrcpyPicker;;<guid>]", but UI Automation does *not* expose it as a child of
# the desktop - the MenuItems show up inside the main window's control-view subtree
# (0 MenuItems before the click, 11 after, all under the window). So scan the window first
# and only fall back to the process's other top-level windows if that finds nothing.
# $WindowDump (a List[string]) records what was seen; the function returns just the
# MenuItems, because a two-value return tuple is more trouble than it is worth in PowerShell.
function Get-OpenMenuItems([int]$ProcId, $MainWindow, [IntPtr]$MainHwnd, $WindowDump) {
    $tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $found = New-Object System.Collections.Generic.List[object]

    foreach ($d in (Get-UiaDescendants $MainWindow)) {
        if ($d.Current.ControlType.ProgrammaticName -eq 'ControlType.MenuItem') { $found.Add($d) }
    }
    [void]$WindowDump.Add('menu items under the main window=' + $found.Count)

    if ($found.Count -eq 0) {
        $child = $tw.GetFirstChild([System.Windows.Automation.AutomationElement]::RootElement)
        while ($null -ne $child) {
            $pid2 = -1
            try { $pid2 = $child.Current.ProcessId } catch { }
            if ($pid2 -eq $ProcId) {
                $hwnd = [IntPtr]::Zero
                try { $hwnd = (New-Object IntPtr($child.Current.NativeWindowHandle)) } catch { }
                if ($hwnd -ne [IntPtr]::Zero -and $hwnd -ne $MainHwnd) {
                    [void]$WindowDump.Add('fallback window ' + $child.Current.ControlType.ProgrammaticName +
                        '/' + $child.Current.ClassName + '/' + $child.Current.Name)
                    foreach ($d in (Get-UiaDescendants $child)) {
                        if ($d.Current.ControlType.ProgrammaticName -eq 'ControlType.MenuItem') { $found.Add($d) }
                    }
                }
            }
            $child = $tw.GetNextSibling($child)
        }
        [void]$WindowDump.Add('menu items after desktop scan=' + $found.Count)
    }

    # plain return on purpose: the caller wraps it in @(), and a comma-wrapped List would
    # arrive as one element that happens to be the list itself.
    return $found
}

function Get-NavBarWindow([int]$ProcId, [IntPtr]$MainHwnd, [string]$MarkerId, $WindowDump) {
    $tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $child = $tw.GetFirstChild([System.Windows.Automation.AutomationElement]::RootElement)
    while ($null -ne $child) {
        $pid2 = -1
        try { $pid2 = $child.Current.ProcessId } catch { }
        $hwnd = [IntPtr]::Zero
        try { $hwnd = (New-Object IntPtr($child.Current.NativeWindowHandle)) } catch { }
        if ($pid2 -eq $ProcId -and $hwnd -ne [IntPtr]::Zero -and $hwnd -ne $MainHwnd) {
            [void]$WindowDump.Add('nav candidate hwnd=' + $hwnd + ' class=' + $child.Current.ClassName +
                ' name=' + $child.Current.Name)
            foreach ($d in (Get-UiaDescendants $child)) {
                $aid = ''
                try { $aid = $d.Current.AutomationId } catch { }
                if ($aid -eq $MarkerId) { return $child }
            }
        }
        $child = $tw.GetNextSibling($child)
    }
    return $null
}

function Get-Wakefulness([string]$adb, [string]$serial) {
    if (-not $adb -or -not (Test-Path -LiteralPath $adb)) { return '' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # adb writes to stderr; Stop would turn that into an exception
    $txt = ''
    try {
        $txt = @(& $adb -s $serial shell dumpsys power 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    } catch { $txt = '' }
    $ErrorActionPreference = $prev
    $m = [regex]::Match($txt, 'mWakefulness=(\w+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Invoke-NavBarChecks {
    param($Proc, [IntPtr]$MainHwnd, [int]$MirrorPid, [string]$AdbExe, [string]$Serial, $Dump)

    $fail = @()
    $root = Get-NavBarWindow -ProcId $Proc.Id -MainHwnd $MainHwnd -MarkerId $NavMarker -WindowDump $Dump
    if ($null -eq $root) {
        $fail += 'no navigation bar window appeared after the mirror came up'
        return $fail
    }

    $byId = @{}
    foreach ($d in (Get-UiaDescendants $root)) {
        $aid = ''
        try { $aid = $d.Current.AutomationId } catch { }
        if ($aid) { $byId[$aid] = $d }
    }
    $dump.Add('nav bar buttons found=' + $byId.Count)
    foreach ($id in $NavIds) {
        if (-not $byId.ContainsKey($id)) { $fail += ('navigation bar is missing button ' + $id) }
        else { $dump.Add(('  {0} enabled={1} rect={2}' -f $id, $byId[$id].Current.IsEnabled,
                (Fmt-Rect $byId[$id].Current.BoundingRectangle))) }
    }

    # --- geometry: the bar has to be flush against the mirror window -------------
    $mh = [IntPtr]::Zero
    try { $mh = (Get-Process -Id $MirrorPid -ErrorAction Stop).MainWindowHandle } catch { }
    if ($mh -eq [IntPtr]::Zero) {
        $fail += 'the scrcpy window handle is not resolvable, cannot check the docking geometry'
        return $fail
    }
    $mir = ([System.Windows.Automation.AutomationElement]::FromHandle($mh)).Current.BoundingRectangle
    $nb = $root.Current.BoundingRectangle
    $dump.Add('mirror rect=' + (Fmt-Rect $mir))
    $dump.Add('navbar rect=' + (Fmt-Rect $nb))

    if ([Math]::Abs($nb.Width - $mir.Width) -gt 6) {
        $fail += ('the bar is not the mirror window''s width: bar=' + $nb.Width + ' mirror=' + $mir.Width)
    }
    # UIA rectangles are physical pixels on both sides, so the 1 DIP seam is ~1.5 px here.
    $below = [Math]::Abs($nb.Top - $mir.Bottom - 1)
    $above = [Math]::Abs($nb.Bottom - $mir.Top - 1)
    $inside = [Math]::Abs($nb.Bottom - $mir.Bottom)
    $dump.Add('gaps below=' + $below + ' above=' + $above + ' inside=' + $inside)
    if ([Math]::Min($below, [Math]::Min($above, $inside)) -gt 8) {
        $fail += ('the bar is not attached to the mirror window (closest gap ' +
            [Math]::Min($below, [Math]::Min($above, $inside)) + ' px)')
    }

    # --- it must follow the mirror when that window moves ------------------------
    [void][Smoke.Win]::MoveWindow($mh, ([int]$mir.X + 140), ([int]$mir.Y + 60),
        ([int]$mir.Width), ([int]$mir.Height), $true)
    Start-Sleep -Milliseconds 1200
    $mir2 = ([System.Windows.Automation.AutomationElement]::FromHandle($mh)).Current.BoundingRectangle
    $nb2 = ([System.Windows.Automation.AutomationElement]::FromHandle(
        [IntPtr]$root.Current.NativeWindowHandle)).Current.BoundingRectangle
    $dump.Add('after move: mirror=' + (Fmt-Rect $mir2) + ' navbar=' + (Fmt-Rect $nb2))
    if ([Math]::Abs($mir2.X - $mir.X) -lt 40) { $fail += 'MoveWindow did not move the mirror, the follow check proves nothing' }
    $gap2 = [Math]::Abs($nb2.Top - $mir2.Bottom - 1)
    if ($gap2 -gt 8) { $fail += ('the bar did not follow the mirror window (gap ' + $gap2 + ' px)') }

    # --- the buttons really send keys -------------------------------------------
    # Screen off / screen on is the only key pair whose effect can be read back
    # without depending on what happens to be in the foreground, and it restores
    # the device to the state it started in.
    #
    # "off" is Asleep *or* Dozing: measured on the bench Pad 6, KEYCODE_SLEEP lands
    # in Doze within a second, so insisting on Asleep alone fails a working feature.
    $probes = @(
        [pscustomobject]@{ Id = 'btnNavSleep'; Want = @('Asleep', 'Dozing') },
        [pscustomobject]@{ Id = 'btnNavWake'; Want = @('Awake') }
    )
    foreach ($probe in $probes) {
        $id = $probe.Id
        if (-not $byId.ContainsKey($id)) { $fail += ('cannot test ' + $id + ': not found'); continue }
        $pattern = $null
        if (-not $byId[$id].TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            $fail += ($id + ' is not invokable')
            continue
        }
        $seen = ''
        for ($i = 0; $i -lt 12; $i++) {
            if ($i % 3 -eq 0) { $pattern.Invoke() }   # press again only if polling says it did not take
            Start-Sleep -Milliseconds 700
            $seen = Get-Wakefulness -adb $AdbExe -serial $Serial
            if ($probe.Want -contains $seen) { break }
            Write-Step ($id + ' -> wakefulness=' + $seen + ' (want ' + ($probe.Want -join '/') + ', poll ' + ($i + 1) + ')')
            Start-Sleep -Milliseconds 300
        }
        $dump.Add($id + ' left wakefulness=' + $seen)
        if ($probe.Want -notcontains $seen) {
            $fail += ($id + ' did not put the device in one of ' + ($probe.Want -join '/') + ' (saw ' + $seen + ')')
        } else {
            Write-Step ($id + ' -> ' + $seen)
        }
    }
    return $fail
}

function Invoke-DeviceScenario {
    param([int]$CastWaitSeconds = 18)

    Write-Step '=== scenario Device (context menu + cast) ==='
    $fail = @()
    $preScrcpyPids = @()
    $dump = New-Object System.Collections.Generic.List[string]
    $handle = [IntPtr]::Zero

    $cfg = Join-Path $env:TEMP ('picker-smoke-cfg-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    $origCfg = $env:SCRCPY_CONFIG_DIR
    $p = $null
    try {
        $env:SCRCPY_CONFIG_DIR = $cfg
        # -no-scan: the drive walk would otherwise burn ~8s on every one of the three runs
        $p = Start-Process -FilePath $Exe -ArgumentList @('-no-scan') -PassThru -WorkingDirectory $exeDir
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            $p.Refresh()
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $handle = $p.MainWindowHandle; break }
        }
        if ($handle -eq [IntPtr]::Zero) { throw 'main window never appeared' }

        # wait for discovery to produce a row
        $row = $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 3
            $all = Get-UiaDescendants ([System.Windows.Automation.AutomationElement]::FromHandle($handle))
            $rows = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.DataItem' })
            if ($rows.Count -gt 0) { $row = $rows[0]; break }
        }
        if ($null -eq $row) { throw 'no device row appeared - is a device attached and authorized?' }

        # A virtualised DataGrid row reports a rect that is wider than the window (it spans
        # the whole scrollable extent), so click the middle of the row *as much of it as is
        # actually on screen*.
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $wr = $root.Current.BoundingRectangle

        # ... and if the window hangs off the desktop, pull it back first: a click at an
        # off-screen coordinate lands on whatever else is there, not on the row.
        $vx = [Smoke.Win]::GetSystemMetrics(76)   # SM_XVIRTUALSCREEN
        $vy = [Smoke.Win]::GetSystemMetrics(77)
        $vw = [Smoke.Win]::GetSystemMetrics(78)   # SM_CXVIRTUALSCREEN
        $vh = [Smoke.Win]::GetSystemMetrics(79)
        $dump.Add('virtual screen=' + $vx + ',' + $vy + ' ' + $vw + 'x' + $vh)
        if ($wr.X + $wr.Width -gt ($vx + $vw) -or $wr.Y + $wr.Height -gt ($vy + $vh)) {
            [void][Smoke.Win]::MoveWindow($handle, ($vx + 10), ($vy + 10), [int]$wr.Width, [int]$wr.Height, $true)
            Start-Sleep -Milliseconds 800
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
            $wr = $root.Current.BoundingRectangle
            Write-Step ('moved the window, now ' + $wr.X + ',' + $wr.Y)
        }

        $r = $row.Current.BoundingRectangle
        $dump.Add('window rect=' + $wr.X + ',' + $wr.Y + ' ' + $wr.Width + 'x' + $wr.Height)
        $dump.Add('row rect=' + $r.X + ',' + $r.Y + ' ' + $r.Width + 'x' + $r.Height)
        $left = [Math]::Max($r.X, $wr.X)
        $right = [Math]::Min($r.X + $r.Width, $wr.X + $wr.Width)
        $top = [Math]::Max($r.Y, $wr.Y)
        $bottom = [Math]::Min($r.Y + $r.Height, $wr.Y + $wr.Height)
        if ($right - $left -lt 20 -or $bottom - $top -lt 10) { throw 'the row is not visible on screen' }
        $cx = [int](($left + $right) / 2)
        $cy = [int](($top + $bottom) / 2)
        $dump.Add('click point=' + $cx + ',' + $cy)

        # right-click -> the per-row context menu
        [void][Smoke.Win]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 500
        Click-At -X $cx -Y $cy -Button 'right'
        Start-Sleep -Seconds 2
        $wins = New-Object System.Collections.Generic.List[string]
        $menuRoot = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $menuItems = @(Get-OpenMenuItems -ProcId $p.Id -MainWindow $menuRoot -MainHwnd $handle -WindowDump $wins)
        foreach ($w in $wins) { $dump.Add('  scan ' + $w) }
        $dump.Add('menu items=' + $menuItems.Count)
        $menuNames = @{}
        foreach ($mi in $menuItems) {
            $n = ''
            try { $n = $mi.Current.Name } catch { }
            $dump.Add(('  MenuItem enabled={0} "{1}"' -f $mi.Current.IsEnabled, $n))
            if ($n) { $menuNames[$n] = $true }
        }
        Write-Step ('context menu items=' + $menuItems.Count)
        if ($menuItems.Count -eq 0) {
            $fail += 'right-click produced no context menu'
        } else {
            foreach ($cap in $AlwaysMenu) {
                if (-not $menuNames.ContainsKey($cap)) { $fail += ('context menu is missing an entry: ' + $cap) }
            }
        }
        Send-Escape
        Start-Sleep -Milliseconds 800

        # double-click -> cast
        $preScrcpyPids = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        Click-At -X $cx -Y $cy -Button 'left' -Clicks 2
        Write-Step ('double-clicked the row, waiting ' + $CastWaitSeconds + 's for scrcpy')
        Start-Sleep -Seconds $CastWaitSeconds

        $scrcpy = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue |
            Where-Object { $preScrcpyPids -notcontains $_.Id })
        $dump.Add('scrcpy processes=' + $scrcpy.Count)
        foreach ($s in $scrcpy) { $dump.Add('  pid=' + $s.Id + ' start=' + $s.StartTime) }
        Write-Step ('scrcpy processes=' + $scrcpy.Count)
        if ($scrcpy.Count -eq 0) { $fail += 'double-click did not leave a running scrcpy process' }

        # The navigation bar only exists while a mirror is up, so its checks hang off
        # this scenario. adb is read straight from the tools folder next to the exe.
        if ($scrcpy.Count -gt 0) {
            $adbExe = Join-Path $exeDir 'tools\adb.exe'
            if (-not (Test-Path -LiteralPath $adbExe)) {
                $cmd = (Get-Command adb -ErrorAction SilentlyContinue)
                if ($cmd) { $adbExe = $cmd.Source } else { $adbExe = '' }
            }
            $serial = ''
            if ($adbExe) {
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $lines = @(& $adbExe devices 2>&1 | ForEach-Object { [string]$_ })
                $ErrorActionPreference = $prev
                $one = @($lines | Where-Object { $_ -match '\tdevice$' } | Select-Object -First 1)
                if ($one.Count) { $serial = ($one[0] -split '\t')[0] }
            }
            Write-Step ('nav bar checks (adb=' + $adbExe + ' serial=' + $serial + ')')
            $navFail = @(Invoke-NavBarChecks -Proc $p -MainHwnd $handle -MirrorPid $scrcpy[0].Id `
                -AdbExe $adbExe -Serial $serial -Dump $dump)
            foreach ($m in $navFail) { $fail += $m }
        }

        $p.Refresh()
        if ($p.HasExited) { throw 'the picker exited while casting' }

        $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $rr = $root.Current.BoundingRectangle
        if ($rr.Width -gt 10 -and $rr.Height -gt 10) {
            $bmp = New-Object System.Drawing.Bitmap([int]$rr.Width, [int]$rr.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen([int]$rr.X, [int]$rr.Y, 0, 0, (New-Object System.Drawing.Size([int]$rr.Width, [int]$rr.Height)))
            $png = Join-Path $OutDir 'Device.png'
            $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose(); $bmp.Dispose()
            Write-Step ('screenshot ' + $png)
        }
    }
    catch {
        $fail += ('exception: ' + $_.Exception.Message)
        Write-Host $_.ScriptStackTrace
    }
    finally {
        # close the mirror window first: the picker owns it and the user should get
        # the bench back exactly as it was. Only kill the scrcpy processes this run
        # started - a mirror the developer opened by hand is not ours to terminate.
        foreach ($s in @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue)) {
            if ($preScrcpyPids -notcontains $s.Id) {
                Write-Step ('stopping scrcpy pid=' + $s.Id)
                try { $s.Kill() } catch { }
            }
        }
        # A bar that outlives its mirror would be an orphan HUD the user cannot get rid of.
        if ($p -and -not $p.HasExited) {
            Start-Sleep -Milliseconds 1500
            $stray = Get-NavBarWindow -ProcId $p.Id -MainHwnd $handle -MarkerId $NavMarker `
                -WindowDump (New-Object System.Collections.Generic.List[string])
            if ($stray) { $fail += 'the navigation bar stayed open after the mirror process died' }
            else { Write-Step 'nav bar retired with the mirror' }
        }
        if ($handle -ne [IntPtr]::Zero) {
            [void][Smoke.Win]::PostMessage($handle, 0x10, [IntPtr]0, [IntPtr]0)
        }
        if ($p) {
            $p.WaitForExit(8000) | Out-Null
            if (-not $p.HasExited) { Write-Step 'still alive after WM_CLOSE, killing'; $p.Kill() }
        }
        if ($origCfg) { $env:SCRCPY_CONFIG_DIR = $origCfg } else { Remove-Item Env:SCRCPY_CONFIG_DIR -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $cfg -Recurse -Force -ErrorAction SilentlyContinue

        $dumpPath = Join-Path $OutDir 'uitree-Device.txt'
        [IO.File]::WriteAllLines($dumpPath, $dump, [Text.UTF8Encoding]::new($true))
        Write-Step ('uitree ' + $dumpPath)
    }

    foreach ($m in $fail) { Write-Host ('   X ' + $m) }
    return $fail.Count
}

# --- offline-row scenario -----------------------------------------------------
# The cached-device branch needs no hardware: seed a devices.json that mentions a device
# that is definitely not connected, and the grid has to render it greyed out with only the
# three menu entries that make sense for an absent phone. 192.0.2.0/24 is TEST-NET-1, so
# even if the app tries to reconnect to the remembered endpoint nothing real is touched.
function Invoke-OfflineScenario {
    Write-Step '=== scenario Offline (cached device, no hardware) ==='
    $fail = @()
    $dump = New-Object System.Collections.Generic.List[string]
    $handle = [IntPtr]::Zero

    $alias = 'zz-smoke-offline'
    $cfg = Join-Path $env:TEMP ('picker-smoke-cfg-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    $json = '{"devices":{"smokeoffline01":{"ts":"2026-01-01T00:00:00Z","Model":"SmokeModel",' +
        '"Device":"smokedev","Android":"14","Brand":"","DevName":"","WifiIp":"192.0.2.11",' +
        '"Battery":"","Charging":"","Alias":"' + $alias + '","TlsLast":"192.0.2.12:45991",' +
        '"KnownUsb":false}},"settings":{"preferUsb":true,"scanSubnet":false,"toolDir":""}}'
    [IO.File]::WriteAllText((Join-Path $cfg 'devices.json'), $json, [Text.UTF8Encoding]::new($false))

    $origCfg = $env:SCRCPY_CONFIG_DIR
    $p = $null
    try {
        $env:SCRCPY_CONFIG_DIR = $cfg
        $p = Start-Process -FilePath $Exe -ArgumentList @('-no-scan') -PassThru -WorkingDirectory $exeDir
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            $p.Refresh()
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $handle = $p.MainWindowHandle; break }
        }
        if ($handle -eq [IntPtr]::Zero) { throw 'main window never appeared' }

        $row = $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 2
            $all = Get-UiaDescendants ([System.Windows.Automation.AutomationElement]::FromHandle($handle))
            foreach ($it in @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.DataItem' })) {
                $kids = @(Get-UiaDescendants $it)
                foreach ($k in $kids) {
                    $n = ''
                    try { $n = $k.Current.Name } catch { }
                    if ($n -eq $alias) { $row = $it; break }
                }
                if ($row) { break }
            }
            if ($row) { break }
        }
        if (-not $row) { throw 'the cached device never showed up as an offline row' }

        $rowKids = Get-UiaDescendants $row
        $cells = @($rowKids | Where-Object { $_.Current.ClassName -eq 'DataGridCell' })
        $cellTexts = @($cells | ForEach-Object { $_.Current.Name })
        $dump.Add('offline row cells: ' + ($cellTexts -join ' | '))
        Write-Step ('offline row cells=' + $cells.Count)
        if ($cells.Count -lt $Headers.Count) { $fail += ('offline row has ' + $cells.Count + ' cells, expected >= ' + $Headers.Count) }
        if ($cellTexts -notcontains $OfflineText) { $fail += 'the cached row is not labelled as offline' }
        if ($cellTexts -contains $OnlineText) { $fail += 'the cached row claims to be online' }
        # Addr must fall back to the remembered endpoint (TlsLast wins over WifiIp:5555).
        if ($cellTexts -notcontains '192.0.2.12:45991') { $fail += 'offline row does not show the remembered TlsLast address' }

        $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $wr = $root.Current.BoundingRectangle
        $r = $row.Current.BoundingRectangle
        $left = [Math]::Max($r.X, $wr.X); $right = [Math]::Min($r.X + $r.Width, $wr.X + $wr.Width)
        $top = [Math]::Max($r.Y, $wr.Y); $bottom = [Math]::Min($r.Y + $r.Height, $wr.Y + $wr.Height)
        if ($right - $left -lt 20 -or $bottom - $top -lt 10) { throw 'the offline row is not visible on screen' }
        $cx = [int](($left + $right) / 2); $cy = [int](($top + $bottom) / 2)
        $dump.Add('click point=' + $cx + ',' + $cy)

        [void][Smoke.Win]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 500
        Click-At -X $cx -Y $cy -Button 'right'
        Start-Sleep -Seconds 2
        $wins = New-Object System.Collections.Generic.List[string]
        $menuRoot = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $menuItems = @(Get-OpenMenuItems -ProcId $p.Id -MainWindow $menuRoot -MainHwnd $handle -WindowDump $wins)
        foreach ($w in $wins) { $dump.Add('  scan ' + $w) }
        $names = @()
        foreach ($mi in $menuItems) {
            $n = ''
            try { $n = $mi.Current.Name } catch { }
            $names += $n
            $dump.Add(('  MenuItem enabled={0} "{1}"' -f $mi.Current.IsEnabled, $n))
        }
        Write-Step ('offline context menu items=' + $menuItems.Count)
        $dump.Add('menu=' + ($names -join ' | '))
        if ($menuItems.Count -ne $MenuSplit.Ungated.Count) {
            $fail += ('offline menu has ' + $menuItems.Count + ' entries, expected ' + $MenuSplit.Ungated.Count)
        }
        foreach ($cap in $MenuSplit.Ungated) { if ($names -notcontains $cap) { $fail += ('offline menu is missing: ' + $cap) } }
        foreach ($cap in $MenuSplit.Gated) { if ($names -contains $cap) { $fail += ('offline menu offers a cast entry: ' + $cap) } }
        Send-Escape
        Start-Sleep -Milliseconds 500

        $p.Refresh()
        if ($p.HasExited) { throw 'the picker exited while showing an offline row' }
    }
    catch {
        $fail += ('exception: ' + $_.Exception.Message)
        Write-Host $_.ScriptStackTrace
    }
    finally {
        if ($handle -ne [IntPtr]::Zero) {
            [void][Smoke.Win]::PostMessage($handle, 0x10, [IntPtr]0, [IntPtr]0)
        }
        if ($p) {
            $p.WaitForExit(8000) | Out-Null
            if (-not $p.HasExited) { Write-Step 'still alive after WM_CLOSE, killing'; $p.Kill() }
        }
        if ($origCfg) { $env:SCRCPY_CONFIG_DIR = $origCfg } else { Remove-Item Env:SCRCPY_CONFIG_DIR -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $cfg -Recurse -Force -ErrorAction SilentlyContinue

        $dumpPath = Join-Path $OutDir 'uitree-Offline.txt'
        [IO.File]::WriteAllLines($dumpPath, $dump, [Text.UTF8Encoding]::new($true))
        Write-Step ('uitree ' + $dumpPath)
    }

    foreach ($m in $fail) { Write-Host ('   X ' + $m) }
    return $fail.Count
}

$total = 0
$runs = @()
if ($Scenario -eq 'Both' -or $Scenario -eq 'Healthy') {
    $runs += , @('Healthy', $false, @(), $false)
}
if ($Scenario -eq 'Both' -or $Scenario -eq 'MissingTools') {
    $runs += , @('MissingTools', $true, @('-no-scan'), $true)
}

foreach ($r in $runs) {
    $total += Invoke-Scenario -Name $r[0] -StripPath $r[1] -ExeArgs $r[2] -ToolsFree:$r[3]
}

if ($Scenario -eq 'Both' -or $Scenario -eq 'Offline') {
    $total += Invoke-OfflineScenario
}

# -Scenario Device asks for the on-bench run on its own; with 'Both' it only happens when
# the caller also promised a device, so a machine with nothing plugged in still passes.
if ($Scenario -eq 'Device' -or ($ExpectDevice -and $Scenario -eq 'Both')) {
    $total += Invoke-DeviceScenario
}

Write-Host ''
if ($total -gt 0) {
    Write-Host ('SMOKE FAILED, ' + $total + ' problem(s)')
    exit 1
}
Write-Host 'SMOKE PASSED'
exit 0
