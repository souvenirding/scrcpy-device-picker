# shrink-png.ps1 - downscale a screenshot so it is cheap to eyeball.
# Full-res captures from this 150%-scaled 1530x960 window are bigger than they need
# to be just to confirm the layout rendered.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Width = 1000
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = (Resolve-Path -LiteralPath $Path).Path
$img = [System.Drawing.Image]::FromFile($src)
try {
    $h = [int]($Width * $img.Height / $img.Width)
    $bmp = New-Object System.Drawing.Bitmap($Width, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($img, 0, 0, $Width, $h)
    $out = Join-Path ([IO.Path]::GetDirectoryName($src)) ([IO.Path]::GetFileNameWithoutExtension($src) + '-small.png')
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    # distinct-colour count tells a blank capture (lock screen / unpainted window) from a real one
    $colors = @{}
    $sample = New-Object System.Drawing.Bitmap($out)
    for ($y = 0; $y -lt $sample.Height; $y += 7) {
        for ($x = 0; $x -lt $sample.Width; $x += 7) {
            $c = $sample.GetPixel($x, $y)
            $key = '' + $c.R + ',' + $c.G + ',' + $c.B
            if (-not $colors.ContainsKey($key)) { $colors[$key] = 0 }
            $colors[$key] = $colors[$key] + 1
        }
    }
    $sample.Dispose()
    $top = $colors.GetEnumerator() | Sort-Object -Descending Value | Select-Object -First 3
    Write-Host ('wrote ' + $out + ' ' + $Width + 'x' + $h)
    Write-Host ('distinct sampled colours=' + $colors.Count)
    foreach ($t in $top) { Write-Host ('  ' + $t.Key + ' x' + $t.Value) }
}
finally {
    $img.Dispose()
}
exit 0
