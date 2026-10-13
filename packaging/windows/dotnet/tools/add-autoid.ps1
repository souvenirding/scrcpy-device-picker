# add-autoid.ps1 - one-off: tag the remaining XAML elements with AutomationId so
# smoke-ui.ps1 can assert against ASCII names instead of Chinese captions.
# Idempotent: an element already carrying the attribute is left alone.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'
$resolved = (Resolve-Path -LiteralPath $Path).Path
$text = [IO.File]::ReadAllText($resolved)

# name -> the x:Name token it should attach to
$map = [ordered]@{
    'toolPanel'    = 'x:Name="toolPanel"'
    'bannerInfo'   = 'x:Name="bannerInfo"'
    'btnToolClear' = 'x:Name="btnToolClear"'
    'btnToolScan'  = 'x:Name="btnToolScan"'
    'btnToolApply' = 'x:Name="btnToolApply"'
    'toolDirInput' = 'x:Name="toolDirInput"'
    'dgDevices'    = 'x:Name="DeviceGrid"'
    'toastCard'    = 'x:Name="Toast"'
}

foreach ($k in $map.Keys) {
    $token = $map[$k]
    $attr = 'AutomationProperties.AutomationId="' + $k + '"'
    if ($text.Contains($attr)) { Write-Host ('already tagged: ' + $k); continue }
    if (-not $text.Contains($token)) { Write-Host ('MISSING TOKEN: ' + $k + ' (' + $token + ')'); continue }
    $text = $text.Replace($token, $token + ' ' + $attr)
    Write-Host ('tagged: ' + $k)
}

# DeviceGrid keeps its old field name in code-behind; rename the declaration consistently.
$text = $text.Replace('x:Name="DeviceGrid"', 'x:Name="dgDevices"')

[IO.File]::WriteAllText($resolved, $text, [Text.UTF8Encoding]::new($false))
Write-Host 'done'
