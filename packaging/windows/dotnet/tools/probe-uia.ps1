# probe-uia.ps1 - diagnostic: walk a live ScrcpyPicker window with TreeWalker.
#
# Why TreeWalker instead of FindAll: under PowerShell 5.1 the UIA
# AutomationElement.TrueCondition static field comes back as $null, so FindAll throws
# "value cannot be null (parameter 'condition')". A recursive ControlViewWalker needs
# no condition at all.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$tc = [System.Windows.Automation.AutomationElement]::TrueCondition
Write-Host ('TrueCondition: ' + $(if ($null -eq $tc) { '<NULL>' } else { 'ok' }))

$p = Get-Process -Name 'ScrcpyPicker' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { Write-Host 'no ScrcpyPicker process'; exit 0 }
Write-Host ('pid=' + $p.Id + ' hwnd=' + $p.MainWindowHandle)
if ($p.MainWindowHandle -eq [IntPtr]::Zero) { Write-Host 'no main window'; exit 0 }

$root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)

$tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$count = 0
$lines = @()

function Walk($node, $depth) {
    if ($null -eq $node) { return }
    $script:count++
    if ($script:count -le 200) {
        $t = $node.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
        $script:lines += ('{0}{1,-16} id={2,-16} enabled={3} "{4}"' -f
            (' ' * ($depth * 2)), $t, $node.Current.AutomationId, $node.Current.IsEnabled, $node.Current.Name)
    }
    $child = $tw.getFirstChild($node)
    while ($null -ne $child) {
        Walk $child ($depth + 1)
        $child = $tw.getNextSibling($child)
    }
}

Walk $root 0
Write-Host ('nodes=' + $count)
$out = Join-Path $env:TEMP 'picker-uia-probe.txt'
[IO.File]::WriteAllLines($out, $lines, [Text.UTF8Encoding]::new($true))
Write-Host ('wrote ' + $out)
exit 0
