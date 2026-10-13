# 安装、配置与打包

> 本文是 [README](../README.md) 的详细补充，面向需要**从零装起来**或**打包分发**的人。
> 只想快速跑起来请看 README 的「快速上手」。

## 环境要求

### Windows

- Windows 10/11，直接运行 `ScrcpyPicker.exe`（C# / WPF 单文件 exe，.NET 8 运行时已 self-contained 打进包里，
  无需 PowerShell、无需浏览器、无需另装 .NET）。
  安装版 `ScrcpyPicker-Setup-x64.exe` 会把 exe 与 `tools\` 一起装好；源码构建见 [packaging/windows/README.md](../../packaging/windows/README.md)。
- exe 旁边建议放一个 `tools\` 目录，里面是 **Windows 版 `adb.exe`**（及 `AdbWinApi.dll` / `AdbWinUsbApi.dll`）和 **`scrcpy.exe`**（及依赖 dll）。
  没有 `tools\` 也不会直接罢工：exe 会依次试 `SCRCPY_TOOL_DIR` / `-tools`、记住过的目录、`PATH`、常见安装位置，最后在本机固定盘里
  做一次受限深度搜索，命中就把目录记进 `%APPDATA%\ScrcpyPicker\devices.json`；界面顶部还会给出填目录 / 自动搜索的入口
  （详见下面「工具路径解析逻辑」）。别和别的 platform-tools 混用，adb server 版本不一致会互相把对方踢下线。
- 界面是原生 WPF（Fluent 风格）。Win10 1803 之前或不支持 Mica 的机器上会退成普通底色，功能不受影响。
- 手机侧：Android 11+ 用「无线调试」；Android 10 及以下只能用 `adb tcpip 5555`。

### macOS

> **直接双击 `ScrcpyPicker.app` 不需要装任何东西**：app 是纯原生 Swift 程序（不打包 PowerShell），
> 内嵌 `adb` + `scrcpy`，**29 MB / zip 13 MB**。后端（设备发现 + scrcpy 调度）全部编译进
> 同一个 Swift 二进制（进程内服务，无 HTTP），没有 PowerShell / 脚本运行时。

只有在**从源码重新打包 `.app`** 时才需要准备工具（最终用户无感）：

- **Xcode Command Line Tools**（`xcode-select --install`，提供 `swiftc`）。
- **scrcpy 官方 macos-aarch64 解压包**（含 `adb` 和 `scrcpy` 两个可执行文件），默认放在
  `~/scrcpy-tools`，或用 `SCRCPY_SRC` 覆盖；`build-app.sh` 会把它们内嵌进 app。

- **只保留一份 adb**：brew 的 `android-platform-tools` 与 Android SDK 自带 platform-tools 版本不一致时，
  两个 adb server 会互相把对方踢下线。打包时统一用 `SCRCPY_SRC` 指向的那一份即可。

---

## 目录结构

仓库按平台分好目录，Windows 端只跑 `windows\` + `shared\`，macOS 端只跑 `packaging\macos\` + `shared\`：

```
<你的根目录>\
└─ scrcpy-device-picker\
   ├─ shared\                 devices.example.json（配置示例，仅供参考）
   ├─ assets\                 picker.ico
   └─ packaging\
       ├─ macos\               Swift 原生引擎：main.swift / ScrcpyPicker.swift / NavBar.swift /
       │                       Sources\*.swift（7 个服务层模块）+ Sources\ViewModels\ + Sources\Views\（SwiftUI）
       │                       / Info.plist / build-app.sh
      └─ windows\
         ├─ dotnet\           C# / WPF 工程：ScrcpyPicker.sln + src\（Views/ViewModels/Services）
         │                    + tests\（xUnit 服务层单测）+ tools\（冒烟与静态闸门脚本）
         ├─ Dist\             本地构建产物（ScrcpyPicker.exe + tools\），不入库；发布走 GitHub Releases
         ├─ Setup.iss         安装包脚本
         ├─ build.ps1         构建脚本（只能在 Windows 上跑：WPF 不能交叉编译；顺带产出便携 zip）
         └─ README.md
```

> macOS 用 Swift、Windows 用 C#/WPF 各自原生实现，运行时不需要任何 `.ps1` / `.bat` / PowerShell / 浏览器。
> 仓库里的 `.ps1` 全是构建期与验证期脚本（`packaging\windows\dotnet\tools\`）。

脚本不写死任何绝对路径：adb 与 scrcpy 从 `SCRCPY_TOOL_DIR` → `<exeDir>\tools` → `PATH`
按候选顺序查找，设备缓存 `devices.json` 落在 `%APPDATA%\ScrcpyPicker\`（Windows）或
`~/Library/Application Support/ScrcpyPicker/`（macOS）。

> Windows 端实现全部在 `packaging/windows/dotnet/`（C# / WPF 单文件 exe）。装好后运行
> `ScrcpyPicker.exe` 即可，界面是原生控件表格，不再有本地 HTTP 服务与网页。

`devices.json` 的 `settings` 里这几项（示例见 `shared/devices.example.json`）：

| 键 | 缺省 | 作用 |
|---|---|---|
| `preferUsb` | `true` | 组装设备行时把 USB 通道排在前面（两端都读；界面工具条的「USB 优先」写这里） |
| `scanSubnet` | `true` | **遗留键，两端都只解析、没有代码消费它**：macOS 的 mDNS 与子网扫描实际由 `DeviceService.swift` 里写死的 `allowWireless = false` 把关，Windows 的深度刷新不看这个值 |
| `navBar` | `true` | **仅 Windows**：投屏时是否挂吸附跟随的导航条（界面工具条上的「导航条」开关写这里）。老文件里没这个键按 `true` 处理 |

`settings.toolDir`（仅 Windows）记自动搜索/手工填到的工具目录，与上面几项同层。

---

## `SCRCPY_TOOL_DIR`：把工具指到你自己的位置

如果 scrcpy/adb 不在默认候选目录里，设一个环境变量指过去即可，不用改脚本：

```powershell
# Windows
$env:SCRCPY_TOOL_DIR = 'D:\Tools\android\scrcpy'   # 指向含 scrcpy.exe / adb.exe 的目录
```

```bash
# macOS
export SCRCPY_TOOL_DIR="$HOME/Library/Android/sdk/platform-tools"   # 目录里有 adb / scrcpy
```

### 工具路径解析逻辑（两端通用）

工具定位逻辑在 `Sources/Toolchain.swift`（macOS）/ `Services/ToolchainService.cs`（Windows）实现，按以下顺序
取第一个含 `adb`（与 `scrcpy`）二进制的目录：

1. `$env:SCRCPY_TOOL_DIR`（.app / .exe 运行前设定，或打包时内嵌目录）；Windows 上等价地还有 `-tools <目录>` 命令行参数
2. 配置里记住的目录（仅 Windows：`devices.json` 的 `settings.toolDir`，来自界面「保存并应用」或启动时的自动搜索）
3. `<程序目录>/tools`、`<程序目录>/platform-tools`、`<程序目录>` 本身（macOS app 内嵌在 `Contents/Resources/tools/`；Windows exe 同级 `tools\`）
4. `<程序目录>/../scrcpy`（仓库内开发态：`<repo>/scrcpy/`）
5. `<程序目录>/../../scrcpy`（旧约定：scrcpy 与仓库同级）
6. 常见安装位置（仅 Windows 生效）：`%ANDROID_HOME%\platform-tools`、`%LOCALAPPDATA%\Android\Sdk\platform-tools`、
   `%LOCALAPPDATA%\Programs\scrcpy`、`Program Files\platform-tools`、scoop / chocolatey 的安装目录等
7. `PATH`（兜底）
8. **受限深度的本机自动搜索**（仅 Windows，且只在 1~7 全落空时才跑）：遍历各**固定盘**盘根往下最多 3 层，
   只认目录名是 `platform-tools` / `scrcpy*` 且里面有 `adb.exe` 的目录，跳过 `Windows`、`WinSxS`、`AppData`、
   `ProgramData`、`$Recycle.Bin` 等系统目录，限时 8~10 秒；命中后写回 `settings.toolDir`，下次启动直接命中。
   界面上也能手动点「自动搜索」重跑，或自己填目录。

adb 与 scrcpy 是**各自独立解析**的：只要任意候选目录里有 `scrcpy.exe`，就能和另一个目录里的 `adb.exe` 搭配使用。
`-no-scan` 可以关掉第 8 步（在 CI / 干净机器上想快速失败时用）。

macOS 上找到的可执行文件不带 `.exe` 后缀；Windows 上仍是 `adb.exe` / `scrcpy.exe`。

> **提示文案按平台分开发**。Windows 缺 adb 时，横幅上的那段话由 `ToolchainService.MissingHint()` 直接生成
> （讲 `tools\`、填目录、自动搜索三条路），不经过任何接口；macOS 那边由服务层状态直接驱动界面横幅
> （`brew install --cask android-platform-tools` 那句）。
> 只有在 Windows 上看到 brew 字样才算 bug。

---

## 编码与换行规则（改代码前必读）

> - **`.swift`** 与 Windows 的 **`.cs` / `.xaml`**：UTF-8，中文可随意写
>   （Roslyn 与 `swiftc` 都认无 BOM 的 UTF-8）。
> - **构建脚本** `*.sh` 必须是 **LF**（CRLF 会破坏 `#!` shebang），且尽量保持纯 ASCII。
> - **PowerShell 脚本** `*.ps1`：要 CRLF；**写中文必须带 UTF-8 BOM**（PS 5.1 没 BOM 会按 GBK 读，注释和字符串一起花屏）。
>   `packaging\windows\dotnet\tools\smoke-ui.ps1` 走的是更严的一条线：**整个文件纯 ASCII**，
>   需要中文断言时从 XAML / C# 源码里现读，由 `tools\check-ps1.ps1` 做静态闸门。
> - **Inno Setup 脚本** `Setup.iss`：用 ANSI/UTF-8 无 BOM 均可，但内嵌中文用 ANSI 更稳妥；不要混用 CRLF/LF。
> - 仓库根 `.gitattributes` 已对 `*.sh`、`*.iss`、`*.cs`、`*.xaml` 等强制 `eol=lf` / `eol=crlf`，提交时无需手动改。

---

## macOS 运行与构建

直接双击 `ScrcpyPicker.app` 即可（或 `open ScrcpyPicker.app`）。若需从源码重新打包：

```bash
cd packaging/macos
./build-app.sh            # 需要 Xcode CLT 的 swiftc，且 ~/scrcpy-tools 有 adb + scrcpy
# 产物：packaging/macos/staging/ScrcpyPicker.app 与 packaging/dist/ScrcpyPicker-<ver>-<arch>.zip
```

app 无本地 HTTP 服务，界面与后端在同一个进程内直调（MVVM：SwiftUI 视图 → ViewModel → `DeviceService`）。
**投屏目标由服务层按设备 Key 重新计算**，绝不信任界面传来的地址串；窗口不可见（最小化/被遮挡）时
服务层自动暂停刷新，恢复可见立即补一轮。

### 默认只发现 USB

macOS app 当前**默认只自动发现 USB 设备**：mDNS 无线调试与子网 5555 扫描的代码已就位，但 `DeviceService.swift`
里 `allowWireless` 默认为 `false`，界面上的「无线/扫描」标识显示为关闭状态。如需开启，需自行构建时把该参数
改为 `true`，再按 [配对与排错](pairing-and-troubleshooting.md) 配对。

> macOS 的「本地网络」隐私权限会拦截 mDNS 广播与局域网扫描：首次触发时系统会弹窗询问，
> 若误拒，需到「系统设置 → 隐私与安全性 → 本地网络」手动放行 `ScrcpyPicker`，
> 否则无线/子网通道会静默搜不到设备。

---

## 打包与发布

- **macOS**：原生 Swift 二进制 + 内嵌 tools，**已不打包 PowerShell**（方案「原生化」）。
- **Windows**：C# / WPF 单文件 exe（.NET 8 self-contained + 单文件打包），原生控件界面，
  用户机零 PowerShell / 浏览器 / .NET 依赖。exe 74 MB 上下，比 Go 版大 8 倍，换的是「拷一个文件就能跑」。
  发布物有两种形态：**便携 zip**（`ScrcpyPicker-win-x64.zip`，exe + `tools\` + 换机说明，解压即用）和
  **安装程序**（`Setup.iss` → `ScrcpyPicker-Setup-x64.exe`，带开始菜单/桌面快捷方式与卸载）。
  成品不上 git——双平台 zip 统一上传 [GitHub Releases](https://github.com/souvenirding/scrcpy-device-picker/releases)。

### macOS `.app` Bundle

构建脚本：`packaging/macos/build-app.sh`（需要 Xcode Command Line Tools 的 `swiftc`）

```bash
# 前置：已下载并解压 scrcpy (macos-aarch64.tar.gz)
# 默认源路径：~/scrcpy-tools（scrcpy + adb），可用 SCRCPY_SRC 覆盖，APP_VERSION 改版本号

cd packaging/macos
./build-app.sh
# 产物：
#   packaging/macos/staging/ScrcpyPicker.app  （可直接双击/open）
#   packaging/dist/ScrcpyPicker-1.0.0-arm64.zip
```

编译的 Swift 源文件：

| 文件 | 职责 |
|---|---|
| `main.swift` | 入口 |
| `ScrcpyPicker.swift` | SwiftUI 主窗口 + MVVM 装配（AppDelegate） |
| `NavBar.swift` | 投屏时的浮动导航 HUD（NSPanel 壳 + SwiftUI 按钮内容） |
| `Sources/Toolchain.swift` | 定位并调用 adb / scrcpy |
| `Sources/ConfigStore.swift` | `~/Library/Application Support/ScrcpyPicker/devices.json` 读写 |
| `Sources/Discovery.swift` | 三通道发现 + 设备详情 + 缓存 |
| `Sources/ServiceTypes.swift` | 服务层强类型契约（行视图模型 / 结果枚举 / 快照载荷） |
| `Sources/RowBuilder.swift` | 设备行组装（强类型 DeviceRowVM） |
| `Sources/DeviceService.swift` | 进程内设备服务（原 `/api/*` 路由语义 + 10s 刷新循环） |
| `Sources/CastManager.swift` | scrcpy 进程管理、复用判定、就绪探测 |
| `Sources/ViewModels/DeviceListViewModel.swift` | 主窗口 ViewModel（状态 / 命令 / toast·banner 状态机） |
| `Sources/ViewModels/NavBarViewModel.swift` | 导航条 ViewModel（显隐状态 + 按键命令） |
| `Sources/Views/*.swift`（6 个） | SwiftUI 视图：主窗口组合根 / 行视图 / 右键菜单 / 横幅 / 进度卡片 / 导航条按钮 |

> 自带原生窗口（SwiftUI），不依赖外部浏览器。未经代码签名与公证，首次从另一台机器拷贝并双击会被
> Gatekeeper 拦，**右键 → 打开** 即可绕过（只需一次）。本地构建后直接 `open` 不受影响。

**自包含性核对**（2026-10-12 实测）：app **29 MB**（tools 28 MB + Swift 二进制 675 KB），
zip 13 MB；包内**没有 pwsh**。`otool -L` 显示二进制只链 `Cocoa` / `SwiftUI` / `Combine` 等系统框架
（无 WebKit），`scrcpy` / `adb` 也都不引用 `/opt/homebrew` 或个人目录下的 dylib → 拷到干净的 Mac 上双击即可跑。


> ⚠️ 打包用的 `scrcpy` 必须是**自带静态依赖**的那一份。Homebrew 装的 `scrcpy` 会动态链接
> `/opt/homebrew/opt/sdl2/lib/...` 等 brew 私有路径，直接拷进 app 会在别的机器上因缺少 dylib 而打不开。
> 换源后记得用 `otool -L <scrcpy> | grep -i homebrew` 复核一次。

### Windows：便携 zip 与 `Setup.exe`

Windows 端是 **C# / WPF 单文件 exe**（`packaging/windows/dotnet/`），不依赖 PowerShell、浏览器，也不依赖 WebView2。
上一代的 **Go + WebView2** 实现（`packaging/windows/go/`）已删除。

构建脚本：`packaging/windows/build.ps1`。**只能在 Windows 上构建**——WPF 依赖 Windows 桌面运行时与 XAML 编译，
交叉编译行不通（Go 版当年可以在 macOS 上 `cross-build.sh`，那个脚本已随之删除）。
安装脚本细节见 [packaging/windows/README.md](../../packaging/windows/README.md)。

前置（仅构建 / 打包时需要，用户机器不需要）：
1. 装 **.NET 8 SDK**。注意「PATH 上有 dotnet」不等于「有 SDK」：只装过运行时的那台机器上，
   `dotnet --version` 会报 `No .NET SDKs were found`。`build.ps1` 会按 `-Dotnet` 参数 →
   `SCRCPY_DOTNET` → PATH → `DOTNET_ROOT` → Program Files 的顺序挑一个能答出 8.x 的 host，
   SDK 装在非默认位置时用前两者指过去。
2. 下载 [scrcpy win64 zip](https://github.com/genymobile/scrcpy/releases) 与
   [Android Platform-Tools](https://developer.android.com/tools/release-notes)（含 `adb.exe` 及配套 dll），
   放入 `Dist\tools\`。
3. 安装 [Inno Setup 6](https://jrsoftware.org/isinfo.php) 用于打安装包（仅在 Windows 上；需在 `staging\` 准备好 exe 与 `tools\`）。

```powershell
cd packaging\windows
powershell -ExecutionPolicy Bypass -File build.ps1 -Tests
# 产物：packaging\windows\Dist\ScrcpyPicker.exe（约 74 MB，self-contained 单文件）
#      packaging\windows\Dist\ScrcpyPicker-win-x64.zip（约 76 MB 便携包，-NoZip 可跳过）
# 无头冒烟：ScrcpyPicker.exe --selftest -out %TEMP%\selftest.json  （退出码 0 = adb 已解析）
```

**便携 zip**（换电脑用的那一份）里是 `ScrcpyPicker\ScrcpyPicker.exe` + `ScrcpyPicker\tools\*`
（adb.exe / scrcpy.exe / SDL3 与 ffmpeg 那几颗 dll / `scrcpy-server` / 上游 `LICENSE.txt`）+
`ScrcpyPicker\README.txt`（中文换机说明，UTF-8 带 BOM）。解压到任意目录双击即用，
新机器上**不需要再找任何依赖**：.NET 运行时压在 exe 里，adb / scrcpy 走 exe 同级的 `tools\`。
只有配置不在这个包里——备注名与记住的工具目录在 `%APPDATA%\ScrcpyPicker\devices.json`，要迁移请单独拷那一个文件。

安装后桌面出现「Scrcpy 设备选择器」快捷方式，双击即启动原生窗口。

**运行时自包含**：`Setup.iss` 把 `ScrcpyPicker.exe`（.NET 运行时与 WPF 原生 dll 都压在单文件里）与
`tools\`（scrcpy.exe + adb.exe + 依赖库）装进 `{app}`，所以**用户机器上不需要预装 PowerShell、.NET、scrcpy 或 adb**。
单文件首次运行会解包到 `%TEMP%\.net`，比之后几次慢一两秒。
Inno Setup 没有 macOS 版，安装包必须在 Windows 上构建。
