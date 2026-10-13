# ============================================================
#  build.ps1 - 在 Windows 上构建 ScrcpyPicker（C# / WPF 单文件 exe）
#
#  用法:
#    powershell -ExecutionPolicy Bypass -File build.ps1              # 发布
#    powershell -ExecutionPolicy Bypass -File build.ps1 -Tests       # 先跑单元测试再发布
#    powershell -ExecutionPolicy Bypass -File build.ps1 -NoSingleFile # 出目录版（调试启动更快）
#    powershell -ExecutionPolicy Bypass -File build.ps1 -NoZip       # 只更 exe，不出便携包
#
#  产物: Dist\ScrcpyPicker.exe（self-contained 单文件，约 74 MB）
#        Dist\tools\  里放 adb.exe / scrcpy.exe 及配套 dll，随 exe 一起分发。
#        Dist\ScrcpyPicker-win-x64.zip  便携包 = exe + tools + 换机说明，解压即用。
#
#  为什么没有 cross-build 了：WPF 依赖 Windows 桌面运行时与 XAML 编译，
#  在 macOS / Linux 上交叉编译不出来（Go 版可以，那套已经删掉了）。
#  Windows 端只能在 Windows 上构建。
# ============================================================
[CmdletBinding()]
param(
    [switch]$Tests,
    [string]$Configuration = 'Release',
    [switch]$NoSingleFile,
    [switch]$NoZip,
    [string]$Dotnet = ''
)

$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    throw 'WPF 只能在 Windows 上构建，macOS / Linux 请改用 packaging/macos/build-app.sh 打 macOS 版'
}

$root = Split-Path $MyInvocation.MyCommand.Path
$proj = Join-Path $root 'dotnet\src\ScrcpyPicker\ScrcpyPicker.csproj'
$testProj = Join-Path $root 'dotnet\tests\ScrcpyPicker.Tests\ScrcpyPicker.Tests.csproj'
$dist = Join-Path $root 'Dist'
$publishDir = Join-Path $root 'dotnet\publish'

# 机器上"有 dotnet"不等于"有 SDK"：只装过运行时的话，C:\Program Files\dotnet\dotnet.exe
# 会在 PATH 里挡在前面，`dotnet build` 却报 "No .NET SDKs were found"。
# 所以逐个候选问一次 --version，谁能答出 8.x 以上才用谁。
function Test-DotnetSdk([string]$exe) {
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { return $null }
    # PS 5.1 下原生命令往 stderr 吐东西时，2>&1 会把它变成 error record，
    # 外层 $ErrorActionPreference='Stop' 就会当场炸掉——这里临时降成 Continue。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @()
    try {
        $lines = @(& $exe --version 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } catch {
        $code = 1
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { return $null }
    $v = @($lines | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+' } | Select-Object -Last 1)
    if (-not $v) { return $null }
    $ver = $v.Trim()
    if ([int](($ver -split '\.')[0]) -lt 8) { return $null }
    return [pscustomobject]@{ Exe = $exe; Version = $ver }
}

$candidates = @()
if ($Dotnet) { $candidates += $Dotnet }
if ($env:SCRCPY_DOTNET) { $candidates += $env:SCRCPY_DOTNET }
$onPath = (Get-Command dotnet -ErrorAction SilentlyContinue)
if ($onPath) { $candidates += $onPath.Source }
if ($env:DOTNET_ROOT) { $candidates += (Join-Path $env:DOTNET_ROOT 'dotnet.exe') }
$candidates += (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'dotnet\dotnet.exe') }
$candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe')

$found = $null
foreach ($c in $candidates) {
    if ($c -and -not [IO.Path]::IsPathRooted($c)) {
        $cmd = (Get-Command $c -ErrorAction SilentlyContinue)
        if ($cmd) { $c = $cmd.Source }
    }
    $found = Test-DotnetSdk $c
    if ($found) { break }
}
if (-not $found) {
    throw ('没找到 .NET 8+ SDK（试过的候选: ' + ($candidates -join '; ') +
        '）。装一个 SDK，或用 -Dotnet <dotnet.exe 全路径> / 环境变量 SCRCPY_DOTNET 指过来: ' +
        'https://dotnet.microsoft.com/download/dotnet/8.0')
}
$dotnetExe = $found.Exe
Write-Host (">> dotnet " + $found.Version + ' @ ' + $dotnetExe)

if ($Tests) {
    Write-Host '>> 单元测试 ...'
    & $dotnetExe test $testProj -c $Configuration --nologo -v m
    if ($LASTEXITCODE -ne 0) { throw '单元测试没通过，先修测试再发布' }
}

# 单文件开关在这里覆盖 csproj：调试时出目录版启动更快（不用每次解包 74 MB）
$single = 'true'
if ($NoSingleFile) { $single = 'false' }

Write-Host ">> dotnet publish ($Configuration, win-x64, self-contained, PublishSingleFile=$single) ..."
if (Test-Path $publishDir) { Remove-Item -Recurse -Force $publishDir }
& $dotnetExe publish $proj -c $Configuration -r win-x64 --self-contained true `
    -p:PublishSingleFile=$single `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=$single `
    -o $publishDir --nologo -v m
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish 失败' }

$exe = Join-Path $publishDir 'ScrcpyPicker.exe'
if (-not (Test-Path $exe)) { throw "发布产物不存在: $exe" }

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
Copy-Item -LiteralPath $exe -Destination (Join-Path $dist 'ScrcpyPicker.exe') -Force
$mb = [math]::Round((Get-Item (Join-Path $dist 'ScrcpyPicker.exe')).Length / 1MB, 1)
Write-Host ">> 已更新 $dist\ScrcpyPicker.exe ($mb MB)"

# 工具目录：adb / scrcpy 是独立二进制，不塞进 exe 里，而是放在旁边的 tools\，
# 由下面的便携 zip 一起打包。目录必须存在，换机器 clone 下来才知道往哪儿放。
$tools = Join-Path $dist 'tools'
if (-not (Test-Path $tools)) { New-Item -ItemType Directory -Path $tools | Out-Null }
if (-not (Test-Path (Join-Path $tools 'adb.exe'))) {
    Write-Host '>> 注意: Dist\tools 里没有 adb.exe，运行时会去找 PATH / 常见安装位置，或弹「工具目录」面板让你指。'
}

# ---- 便携 zip：整个文件夹拷到新电脑解压即用 ------------------------------------
# 为什么值得单独出一个包：exe 是 self-contained 的（.NET 运行时 + WPF 原生 dll +
# WPF-UI / CommunityToolkit 全在单文件里），新电脑不用装任何东西；唯一的外部依赖
# 是旁边 tools\ 里的 adb / scrcpy，一起打进来就是"开箱即用"。
if ($NoZip) {
    Write-Host '>> -NoZip：跳过便携包'
} elseif ($single -ne 'true') {
    Write-Host '>> 跳过便携包：-NoSingleFile 出的是目录版，exe 旁边还散着 dll，打包了也不能只拷一个文件。'
} else {
    $stage = Join-Path $env:TEMP ('scrcpy-picker-zip-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $inner = Join-Path $stage 'ScrcpyPicker'
    New-Item -ItemType Directory -Path $inner -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $dist 'ScrcpyPicker.exe') -Destination $inner -Force

    $haveTools = Test-Path (Join-Path $tools 'adb.exe')
    if ($haveTools) {
        Copy-Item -LiteralPath $tools -Destination (Join-Path $inner 'tools') -Recurse -Force
    } else {
        Write-Host '>> 注意: 这个 zip 里没有 tools\，换机后要先在「工具目录」面板指一次 adb。'
    }

    # 换机说明写在包里：迁移时手边通常没有仓库，别让人去猜配置文件在哪。
    $note = @(
        '投屏设备选择器（Windows）',
        '',
        '1. 整个 ScrcpyPicker 文件夹解压到任意位置（exe 自己找旁边的 tools\，别把两者拆开）。',
        '2. 双击 ScrcpyPicker.exe。不需要装 .NET、不需要装 adb / scrcpy。',
        '3. 手机开 USB 调试插上即可；无线调试在手机上「开发者选项 → 无线调试」配对后由程序自动发现。',
        '',
        '换机器要带走的配置：%APPDATA%\ScrcpyPicker\devices.json',
        '（备注名、记住的无线地址、工具目录、导航条开关都在这里；不带走就是全新状态。）',
        '',
        '环境变量（可选）：',
        '  SCRCPY_TOOL_DIR   指定含 adb.exe / scrcpy.exe 的目录',
        '  SCRCPY_CONFIG_DIR 指定配置目录（想让它跟着包走就设成包里的路径）',
        '',
        '命令行：',
        '  ScrcpyPicker.exe -no-scan      启动时不做工具目录自动搜索',
        '  ScrcpyPicker.exe -tools <dir>  临时指定工具目录',
        '  ScrcpyPicker.exe --selftest    无界面自检，结果写 JSON（退出码 0=adb 就绪，2=没找到）',
        ''
    ) -join "`r`n"
    # 包里这个文件名保持纯 ASCII：万一哪天 build.ps1 被存成无 BOM 的 UTF-8，
    # PS 5.1 会按 GBK 解脚本，中文文件名字面量会直接变成磁盘上的乱码文件名（内容还能重生成，名字不能）。
    Set-Content -LiteralPath (Join-Path $inner 'README.txt') -Value $note -Encoding utf8

    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = Join-Path $dist 'ScrcpyPicker-win-x64.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false) | Out-Null
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue

    $zmb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
    Write-Host ">> 便携包: $zip ($zmb MB$(if ($haveTools) { '' } else { '，缺 tools' }))"
}

Write-Host '>> 构建完成。冒烟验证: dotnet\tools\smoke-ui.ps1（UI Automation 真点按钮）'
