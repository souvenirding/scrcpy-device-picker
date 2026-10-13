# ScrcpyPicker — Windows 版（C# / WPF 原生界面）

2026-10-11 起，Windows 端是**原生 WPF 应用**（.NET 8 + [WPF-UI](https://github.com/lepoco/wpfui) 的 Fluent 风格控件），
不再跑「Go 单 exe + 内嵌 HTTP 服务 + WebView2 网页」那一套：没有本地端口、没有浏览器内核依赖，
表格、按钮、右键菜单都是真控件。旧的 Go 实现（`packaging/windows/go/`）已整体删除。

macOS 端仍是 Swift + WKWebView + 内嵌 HTTP 服务，**没有改动**；两端各自独立，
共用的只有 `shared/devices.example.json` 描述的配置格式（`%APPDATA%\ScrcpyPicker\devices.json`
与 macOS 的 `~/Library/Application Support/ScrcpyPicker/devices.json` 字段完全一致，互相能读）。

## 架构

```
ScrcpyPicker.exe  (.NET 8 self-contained 单文件)
├─ Views/MainWindow.xaml        FluentWindow：标题栏 + 工具条 + 横幅 + 工具目录卡片 + DataGrid + 底部状态
├─ Views/NavBarWindow.xaml      无边框自绘导航条：吸附跟随投屏窗口下沿，七颗按键 + ✕
├─ ViewModels/                  MainViewModel（命令、10 秒定时刷新、toast、导航条开关）/ DeviceItem（行视图模型）
└─ Services/
    ├─ ToolchainService.cs      adb / scrcpy 定位：候选顺序 + 受限深度自动搜索 + 版本探测
    ├─ ConfigService.cs         devices.json 读写（原子替换、损坏自愈）
    ├─ DiscoveryService.cs      三通道发现（USB / mDNS 无线调试 TLS / TCP 5555）+ getprop 详情
    ├─ WebRows.cs               在线行 + 缓存离线行 → 界面行（在线优先、按名称排序）
    ├─ CastManager.cs           scrcpy 启动 / 复用 / 孤儿认领 / 日志判就绪
    ├─ NavBarService.cs         每台投屏一条导航条 + 60ms 跟随循环（含按 PID 判活清理）
    ├─ NavBarLayout.cs          导航条的纯几何：物理像素→DIP、下沿/上沿/内叠、圆角朝向（可单测）
    ├─ User32.cs                GetWindowRect / IsIconic / IsWindow
    ├─ ProcessRunner.cs         无窗口子进程 + 输出切分
    └─ Kernel32.cs              进程映像名（PID 复用校验）
```

调用链是「界面 → 服务层」直连，中间没有 HTTP：`/api/*` 那一层随 Go 版一起去掉了，
行为语义（复用窗口、传输名解析、就绪判定、离线置灰）与 macOS 版保持一致。

## 界面与操作

| 位置 | 内容 |
|---|---|
| 工具条 | **刷新**、**深度刷新**（多花几秒做子网 5555 扫描与 mDNS 重发现）、**USB 优先**、**导航条**（总开关） |
| 工具条右侧 | 一行状态：adb.exe / scrcpy.exe 各自的来源与版本，以及无线调试的提示文案 |
| 顶部横幅 | 只在 adb / scrcpy 没解析出来时出现，说清楚缺什么、怎么办（Windows 文案，不会出现 `brew`） |
| 工具目录卡片 | 同上，只在缺工具时出现：填目录「保存并应用」、「自动搜索」、「清除记住的目录」 |
| 设备表 | 设备 / 型号 / 系统 / 连接 / 地址 / 电量 / 状态 七列；离线行置灰并排在在线设备之后 |
| 右下角 toast | 投屏进度与结果：转圈 → ✓「投屏窗口已打开」或 ✕ 带 scrcpy 原话，点一下关闭 |
| 底部 | 「共 N 台 · 上次刷新 HH:mm:ss」 |
| **双击一行** | 投屏（自动选通道：USB → 无线调试 → 5555；同设备重复双击复用已开窗口） |
| **右键一行** | 投屏（自动选通道）/ 用 USB 投屏 / 投屏（不同步剪贴板）/ 强制重新投屏 / 唤醒屏幕 / 返回 / 桌面 / 多任务 / 断开无线会话 / 设置备注名… / 复制地址 / 从列表移除 |
| **导航条**（投屏时出现） | 吸附在**投屏窗口下沿**、与窗口同宽的一条按键条：返回 / 桌面 / 多任务 / 音量- / 音量+ / 息屏 / 唤醒 + ✕。跟随窗口拖动、缩放、最大化（放不下会翻到窗口上沿，最大化时叠在画面底部内侧），窗口最小化它跟着藏、还原自己回来；按住空白拖一下脱离吸附变悬浮条，**双击**恢复吸附。每台投屏各有一条，投屏窗口关掉它自己收掉；总开关在工具条「导航条」上 |

离线行只保留「设置备注名… / 复制地址 / 从列表移除」三项——投屏要有通道，断开无线会话要有 TLS 端口。

> 与 macOS 版的界面差异：两端的导航条都在，形态不同——macOS 是屏幕底部居中的**独立浮动 HUD**（不做窗口吸附，
> 那要 Accessibility 权限），Windows 是**吸附跟随投屏窗口**的那一条；按键都是 `adb shell input keyevent`。
> Windows 关掉主窗口就是退出（没有系统托盘常驻），已经开着的 scrcpy 窗口不受影响。

## 分发形态

```
ScrcpyPicker.exe        <- 单文件 self-contained，约 74 MB，不需要预装 .NET
tools\
  ├─ adb.exe            <- Windows 版 Android Platform-Tools
  ├─ AdbWinApi.dll
  ├─ AdbWinUsbApi.dll
  ├─ scrcpy.exe         <- Windows 版 scrcpy
  ├─ LICENSE.txt        <- scrcpy 上游许可（随包保留）
  └─ *.dll (SDL3 / avcodec / avformat / avutil / swresample / libusb) + scrcpy-server
```

`build.ps1` 除了上面这份 `Dist\`，还会打一个**便携 zip**：`Dist\ScrcpyPicker-win-x64.zip`
（约 76 MB，14 个条目 = exe + `tools\` 的 12 个文件 + 一份 `README.txt`），解压出来就是
`ScrcpyPicker\ScrcpyPicker.exe` + `ScrcpyPicker\tools\*` + `ScrcpyPicker\README.txt`
（中文换机说明，UTF-8 带 BOM），拷到新电脑解压就能跑，
**不需要预装 .NET、不需要 PowerShell、不需要浏览器，也不用再单独找 adb / scrcpy 或它们的 dll**。
用 `-NoZip` 可以跳过这一步；`-NoSingleFile`（出目录版）时自动跳过，因为没有单 exe 可打包。

> 唯一不在这个压缩包里的是配置：设备备注名、记住的工具目录等都在
> `%APPDATA%\ScrcpyPicker\devices.json`，换电脑要迁走请单独拷这一个文件（没做便携化是刻意的，
> 免得把备注名这类本机数据混进发布物）。

`tools/` 不塞进 exe（adb/scrcpy 是独立二进制 + 依赖库），放在 exe 同级的 `tools\` 即可。
exe 启动时按 `SCRCPY_TOOL_DIR` / `-tools` → 配置记住的目录 → `<exeDir>\tools` → `<exeDir>` →
`<exeDir>\..\scrcpy` → 常见安装位置 → `PATH` 依次定位，全落空时再做一次受限深度的本机搜索
（固定盘往下 3 层、8 秒预算，只认名字像 `platform-tools` / `scrcpy*` 且有 `adb.exe` 的目录），
命中即写进 `devices.json` 的 `settings.toolDir`。加 `-no-scan` 可跳过那次搜索。
adb 与 scrcpy 分别解析，可以一个来自 `tools\`、另一个来自 PATH。

## 运行

直接双击 `ScrcpyPicker.exe`。Win10 1803+ 自带 Mica/Fluent 主题支持，不支持的机器上会退成普通底色，
不影响功能。首次运行是单文件解包，比后续启动慢一两秒（解到 `%TEMP%\.net`）。

命令行开关（前缀 `-` 与 `--` 都认）：

- `-tools <目录>`：强制指定 adb/scrcpy 所在目录。
- `-no-scan`：跳过自动搜索（调试时省 8 秒）。
- `--selftest [-out <文件>]`：**不建窗口**跑一遍服务层，把工具链解析结果、设备清单、版本信息写成 JSON
  （默认落 `%TEMP%\scrcpy-picker-selftest.json`）。退出码 `0` = adb 已解析，`2` = 没找到 adb。
  这是发布后的无头冒烟入口。

## 找不到 adb 时

横幅 + 「工具目录」卡片会一起出现：

- **自动搜索**：在本机固定盘里找含 `adb.exe` 的 `platform-tools` / `scrcpy*` 目录，
  结果按「同目录里还有 scrcpy.exe」优先、层级浅的优先排序，点一下就应用并记进配置。
- **手工填目录**：填任意含 `adb.exe` 的文件夹（可以是 `E:\Flash\tools\scrcpy` 这类现成目录，不必和 exe 同级），
  回车或点「保存并应用」；目录里没有 adb 会被直接拒绝并说明原因。
- **清除记住的目录**：把 `settings.toolDir` 清空，回到自动查找顺序。
- 状态行会显示当前 adb / scrcpy 各自的**来源**（指定目录 / 已保存目录 / exe 同级 tools / PATH / 常见安装位置 / 自动搜索），
  排查「到底用的哪一个 adb」时看这里。

## 获取 tools（adb + scrcpy）

- adb：`https://developer.android.com/tools/release-notes` 或 `https://dl.google.com/android/repository/platform-tools-latest-windows.zip` 解压后取 `adb.exe` + `AdbWinApi.dll` + `AdbWinUsbApi.dll`。
- scrcpy：`https://github.com/Genymobile/scrcpy/releases` 下载 `scrcpy-win64-vX.Y.Z.zip`，取 `scrcpy.exe`、`scrcpy-server` 及全部 `.dll`。
- 把上述文件一起放进 `Dist\tools\`。

> 建议使用**静态链接、不依赖 Visual C++ 运行库**的 scrcpy 发行包；若仍缺 `vcruntime140.dll`，一并放入或安装 VC++ 运行库。

## 构建

需要 **Windows + .NET 8 SDK**（`https://dotnet.microsoft.com/download/dotnet/8.0`）。
WPF 依赖 Windows 桌面运行时和 XAML 编译，**没法在 macOS / Linux 上交叉编译**，
所以原来那个 `cross-build.sh` 一并删了——macOS 上只能打 macOS 版。

```powershell
cd packaging\windows
powershell -ExecutionPolicy Bypass -File build.ps1          # 发布 -> Dist\ScrcpyPicker.exe + Dist\ScrcpyPicker-win-x64.zip
powershell -ExecutionPolicy Bypass -File build.ps1 -Tests   # 先跑服务层单元测试再发布
powershell -ExecutionPolicy Bypass -File build.ps1 -NoSingleFile   # 出目录版，调试启动快（自动跳过打 zip）
powershell -ExecutionPolicy Bypass -File build.ps1 -NoZip   # 只出 exe，不生成便携 zip
```

> **PATH 上有 `dotnet` 不代表有 SDK**。只装过 .NET 运行时时，`C:\Program Files\dotnet\dotnet.exe`
> 会抢在 PATH 前面，`dotnet build` 却报 `No .NET SDKs were found`。`build.ps1` 会挨个问候选路径的
> `--version`（`-Dotnet` 参数 → `SCRCPY_DOTNET` → PATH → `DOTNET_ROOT` → Program Files →
> `%LOCALAPPDATA%\Microsoft\dotnet`），挑第一个能答出 8.x 的；都不行就报错并列出试过的路径。
> 把 SDK 装在非默认位置时用 `-Dotnet E:\tools\dotnet\dotnet.exe` 或设 `SCRCPY_DOTNET` 指过去。

便携 zip 是**换电脑不用找依赖**那一份：`Dist\ScrcpyPicker-win-x64.zip`（约 76 MB，14 个条目）里是
`ScrcpyPicker\ScrcpyPicker.exe` + `ScrcpyPicker\tools\*`（adb、scrcpy 及其全部 dll、`scrcpy-server`、上游 `LICENSE.txt`）
+ `ScrcpyPicker\README.txt`（中文换机说明，UTF-8 带 BOM）。`Dist\tools` 里没有 `adb.exe` 时脚本会跳过打包并说明原因。

工程布局：

```
dotnet\ScrcpyPicker.sln
      \src\ScrcpyPicker\          WPF 主工程（Views / ViewModels / Services）
      \tests\ScrcpyPicker.Tests\  xUnit 单测 96 个（工具链解析 / 发现结果 / 配置读写 / 投屏参数 / 导航条几何与开关）
      \tools\                     构建期与验证期脚本（见下）
```

### 自动化冒烟（UI Automation 真点按钮）

```powershell
cd packaging\windows\dotnet
powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke-ui.ps1 `
  -Exe ..\..\Dist\ScrcpyPicker.exe `
  -Xaml src\ScrcpyPicker\Views\MainWindow.xaml `
  -CodeBehind src\ScrcpyPicker\Views\MainWindow.xaml.cs `
  -Scenario Both -ExpectDevice -OutDir <输出目录>
```

> 导航条的 XAML 不用单独传参：脚本按 `-Xaml` 所在目录去找同级的 `NavBarWindow.xaml`，
> 那里面的 AutomationId 与 `Tag="键码"` 就是 `Device` 场景的断言来源。

四个场景：`Healthy`（工具齐全，横幅/工具卡片必须藏起来）、`MissingTools`（把 exe 复制到空目录 + 剥掉
PATH，横幅和工具卡片必须出现）、`Offline`（喂一份 devices.json 给一个不存在的设备，验离线行的置灰文案、
remembered 地址和精简后的右键菜单）、`Device`（台架上有真机时：右键菜单条目齐全 + 双击真的把 scrcpy 拉起来 +
**导航条那一套真机实测**）。

`Device` 场景里导航条查的是：XAML 里声明的 8 个 AutomationId（七颗键 + ✕）在 UIA 树里都在、
键码 `Tag` 与 4/3/187/25/24/223/224 对齐、条宽 = 投屏窗口宽、下沿缝隙 ≤8px、
`MoveWindow` 挪动投屏窗口后缝隙仍然 ≤8px（证明真的在跟随）、
按 **息屏** 后 `adb shell dumpsys power` 的 `mWakefulness` 变成 `Asleep`/`Dozing`、
按 **唤醒** 后回到 `Awake`、杀掉 scrcpy 后按钮条跟着消失（不留孤儿窗）。

脚本是**契约驱动**的：断言用的 AutomationId 取自 XAML、列名从 XAML 里现读、右键菜单条目和在线/离线文案
从 C# 源码里现读，所以界面改了字而脚本没跟着改时会直接报「解析不到」，而不是悄悄放过。
`tools\check-ps1.ps1` 是它自己的静态闸门（纯 ASCII + 双解析器 + 定义了却没调用的函数）。
`tools\probe-uia.ps1` / `tools\probe-menu.ps1` 是排查 UIA 树用的探针，不参与断言。

## 打包为安装程序（Inno Setup 6）

1. 先跑 `build.ps1` 生成 `Dist\ScrcpyPicker.exe`，连同 `Dist\tools\*` 复制到本目录的 `staging\`
   （保持 `staging\ScrcpyPicker.exe` 与 `staging\tools\...`）。
2. 用 Inno Setup 编译：`ISCC.exe Setup.iss`
3. 输出：`..\dist\ScrcpyPicker-Setup-x64.exe`

## 环境变量（可选）

- `SCRCPY_TOOL_DIR`：强制指定 adb/scrcpy 所在目录。
- `SCRCPY_CONFIG_DIR`：强制指定配置目录（默认 `%APPDATA%\ScrcpyPicker`）——单测和冒烟就靠它隔离，
  跑一次测试不会碰你真正的 `devices.json`。

## 与旧版的关系

- **Go + WebView2 版**（2026-10-10 之前）：源码已从 `packaging/windows/go/` 删除，历史在 git 里。
  行为语义（发现规则、投屏复用、配置格式）逐条对照移植，服务层单测里还留着与 Go 行为对齐的断言注释。
- **PowerShell + WPF 版**（更早）：`windows/Picker.ps1` 等已全部移除。仓库里现在只剩构建/验证用的
  `.ps1` 脚本，运行时不再依赖 PowerShell。
