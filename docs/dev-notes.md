# 开发者笔记：架构、文件清单与实现踩坑

> 本文面向**改代码的人**。只想用工具请看 [README](../README.md)。

## 文件清单

| 文件 | 作用 |
|---|---|

| `shared/devices.example.json` | 设备缓存文件的结构示例（仅供阅读，真实缓存由程序写入各平台专属路径，已 gitignore） |
| `assets/picker.ico` | 快捷方式图标（由 scrcpy 的 png 转成 PNG-in-ICO） |
| `packaging/macos/main.swift` / `ScrcpyPicker.swift` / `NavBar.swift` | macOS 入口、SwiftUI 主窗口装配（AppDelegate + MVVM）、浮动导航 HUD 面板（NavBarPanel） |
| `packaging/macos/Info.plist` / `build-app.sh` | macOS `.app` 打包（SwiftUI 界面 + 进程内服务引擎 + NavBar 浮动工具条） |
| `packaging/macos/Sources/*.swift` | 9 个服务层模块 + `ViewModels/`（3 个）+ `Views/`（8 个，见下表） |
| `packaging/windows/dotnet/src/ScrcpyPicker/` | Windows WPF 工程：`Views/`（FluentWindow + DataGrid + 传输卡片 + 吸附导航条）、`ViewModels/`（MVVM）、`Services/`（toolchain/config/discovery/webrows/cast/transfer/process/navbar） |
| `packaging/windows/dotnet/tests/` | xUnit 服务层单测 124 个（工具链候选与搜索、发现结果解析、无线 mDNS 解析、配置读写、投屏参数、CLI、导航条几何与开关、文件互传） |
| `packaging/windows/dotnet/tools/` | 验证脚本：`smoke-ui.ps1`（UI Automation 冒烟）、`check-ps1.ps1`（脚本静态闸门）、`probe-uia.ps1` / `probe-menu.ps1`（UIA 探针）、`shrink-png.ps1` |
| `packaging/windows/Setup.iss` / `build.ps1` | Windows 安装包脚本与构建脚本（**只能在 Windows 上构建**，WPF 不能交叉编译）；`build.ps1` 除了 exe 还产出便携 zip |
| `packaging/windows/Dist/` | 发布产物：`ScrcpyPicker.exe` + `tools\` + `ScrcpyPicker-win-x64.zip` |
| `packaging/dist/` | macOS 发布包：`ScrcpyPicker-<ver>-<arch>.zip`（已 gitignore） |
| `<你的根目录>\scrcpy\` | scrcpy 5.0 本体和它自带的 adb（打包时内嵌进 app / 随 exe 分发） |

### Windows 引擎模块（`packaging/windows/dotnet/src/ScrcpyPicker/`）

| 文件 | 职责 |
|---|---|
| `Services/ToolchainService.cs` | adb / scrcpy 定位：候选顺序、受限深度自动搜索、版本探测、缺失文案 |
| `Services/ConfigService.cs` | `%APPDATA%\ScrcpyPicker\devices.json` 读写（原子替换、损坏自愈、中文不转义） |
| `Services/DiscoveryService.cs` | 三通道发现（USB 每轮、mDNS 每轮主动连接、5555 仅深度）+ getprop 详情解析 + 缓存合并（含换 Key 时迁移旧 Alias） |
| `Services/WebRows.cs` | 在线行 + 离线缓存行 → 界面行（在线优先、按名称排序） |
| `Services/CastManager.cs` | scrcpy 进程管理、复用判定、孤儿认领、日志判就绪 |
| `Services/TransferManager.cs` | 文件互传服务层：五重受理（adb / 在线 / 每设备互斥 / 全局 3 个 / 登记）、live-only 目标、字节实测进度、取消与半包清理 |
| `Services/TransferPaths.cs` | 本机「下载」目录解析（known folder → `%USERPROFILE%\Downloads`，`SCRCPY_DOWNLOAD_DIR` 覆盖） |
| `Models/TransferModels.cs` | 互传的纯逻辑与文案：方向/快捷目录/失败映射/落地命名/候选通道/设备字节测量 |
| `Services/ProcessRunner.cs` | 无窗口子进程执行与输出切分 |
| `Services/User32.cs` | `GetWindowRect` / `IsIconic` / `IsWindow` P/Invoke 声明（导航条跟随用） |
| `Services/NavBarLayout.cs` | 导航条的**纯几何**：物理像素→DIP、投放位置（下沿/上沿/内叠）、圆角朝向，无窗口依赖，单测直接打 |
| `Services/NavBarService.cs` | 每条投屏一个导航条窗口的生命周期 + 60ms 跟随循环（`DispatcherTimer`） |
| `Services/PickerBackend.cs` | 把上面这些缝成界面/自检用的门面 |
| `Services/Kernel32.cs` | `QueryFullProcessImageName`（PID 复用校验） |
| `ViewModels/MainViewModel.cs` | 命令、10 秒定时刷新、toast、工具目录面板、导航条总开关 |
| `ViewModels/TransferCenter.cs` | 传输卡片堆叠（进行中优先、最多三张、溢出汇总）、受理提示卡、行内「传输中」事件 |
| `ViewModels/TransferCardItem.cs` | 单张传输卡片：四态、进度/百分比/取消按钮的可见性 |
| `Views/MainWindow.xaml(.cs)` | FluentWindow 布局 + 逐行右键菜单 + 文件拖放 + 传输卡片区 |
| `Views/NavBarWindow.xaml(.cs)` | 无边框自绘导航条：七颗按钮 + 拖拽脱离 / 双击重新吸附 |
| `App.xaml.cs` | 入口、CLI 解析（`-tools` / `-no-scan` / `--selftest`） |

### macOS 引擎模块（`packaging/macos/Sources/`）

| 文件 | 职责 |
|---|---|
| `Toolchain.swift` | 定位并调用 adb / scrcpy，工具版本探测 |
| `ConfigStore.swift` | `~/Library/Application Support/ScrcpyPicker/devices.json` 读写 |
| `Discovery.swift` | 三通道发现 + 设备详情 + 缓存合并（含换 Key 时迁移旧 Alias） |
| `ServiceTypes.swift` | 服务层强类型契约（DeviceRowVM / 结果枚举 / 快照载荷） |
| `RowBuilder.swift` | 设备行组装（强类型 DeviceRowVM，规则承接原 WebRows） |
| `DeviceService.swift` | 进程内设备服务（原 `/api/*` 路由语义 + 10s 刷新循环 + 暂停态） |
| `CastManager.swift` | scrcpy 进程管理、复用判定、就绪探测 |
| `TransferManager.swift` / `TransferTypes.swift` | 文件互传服务层与强类型契约（与 Windows 版同一套规则） |
| `ViewModels/DeviceListViewModel.swift` | 主窗口 ViewModel（可观察状态 / 命令 / toast·banner 状态机） |
| `ViewModels/NavBarViewModel.swift` | 导航条 ViewModel（isVisible 显隐 + 按键命令） |
| `ViewModels/TransferViewModel.swift` | 传输卡片堆叠、行内传输状态、拖放聚合 |
| `Views/*.swift`（8 个） | SwiftUI 视图：DeviceListScreen / DeviceRowView / DeviceContextMenu / BannerView / CastToastView / NavBarView / TransferCardsView / FilePickPanel |

---

## macOS 版架构要点

`.app` 是**纯原生 Swift 程序**：SwiftUI 原生界面（NSWindow + NSHostingView）+ 进程内服务（`DeviceService`，
无 HTTP、无 WebView）+ adb/scrcpy 调度。整个 app 29 MB、zip 13 MB。

> 仓库里的 `.ps1` 全在 `packaging/windows/dotnet/tools/`，是构建期/验证期脚本，不参与运行。
> **改动发现规则时要同步两处**：`Sources/Discovery.swift`（macOS）与 `Services/DiscoveryService.cs`（Windows）。

### 与 Windows 版的差异

- **导航条形态**：两端都有「返回 / 桌面 / 多任务 / 音量- / 音量+ / 息屏 / 唤醒」按钮条，都走 `adb keyevent`，
  但摆放方式不同。macOS 是独立浮动小条——`.app` 检测到有 scrcpy 进程运行时，在屏幕底部居中弹出 HUD 面板，
  浮在所有窗口之上、可拖到任意位置、scrcpy 全部关闭时自动收起（要做窗口吸附得申请 Accessibility 权限，没做）。
  Windows 的按钮条**吸附在投屏窗口的下边缘、与窗口同宽并跟随移动**（见下文「Windows 导航条吸附机制」），
  每台的投屏各有一条，工具条上的「导航条」开关可整体关掉。
- **右键菜单的按键范围**：Windows 的逐行右键菜单只有「唤醒屏幕 / 返回 / 桌面 / 多任务」四项单发按键，
  音量与息屏只在导航条上；macOS 网页菜单同样只给常用几项。
- **界面形态**：macOS 是 SwiftUI 原生界面（NSWindow + NSHostingView）+ 进程内服务直调，
  没有本地端口也没有 HTTP；Windows 是原生 WPF 控件表格，同样没有本地端口。两端都不存在跨站面，
  两端都没有系统托盘常驻，关掉窗口即退出（已开着的 scrcpy 窗口不受影响，重开时会被认领回去）。
- **命令行自检**：Windows 有 `ScrcpyPicker.exe --selftest [-out 文件]`——不建窗口跑一遍服务层，
  把工具链解析结果 / 设备清单 / 版本写成 JSON，退出码 `0` = adb 已解析、`2` = 没找到 adb，
  发布后的无头冒烟就靠它。macOS 目前没有对应入口（如需，可在 `DeviceService.swift` 加一个自检方法）。

### Windows 无线发现（1.1.0）

Windows 端从 1.1.0 起**主动开启无线扫描**（macOS 仍保持 `allowWireless = false`，未改动）：

- 入口：`PickerBackend.Refresh` 调 `Inventory(deep, allowWireless: true)`；`MainViewModel` 的 10 秒定时刷新同样走这里。
- **mDNS（每轮）**：`EnsureWireless` 执行 `adb mdns services`，`ParseMdnsServices` 只收
  `_adb-tls-connect._tcp` 行（配对服务连上去没意义），从实例名 `adb-<serial>-<hash>` 里提取串号提示写进缓存。
  对尚未在线的端点执行 `adb connect`，成功与否都以 `adb devices` 的 `device` 状态为准确认；
  失败会 `adb disconnect` 掉并在 30 秒内退避，避免 10 秒刷新被一个坏端点拖住。
  `WirelessAlreadyLive` 会在「端点已在线 / 同名 mDNS 传输已在线 / 同串号 USB 已在线」时跳过重复连接。
- **子网 5555（仅深度刷新）**：`LocalSubnetPrefix` 选一条有 IPv4 网关的物理网卡（跳过回环/APIPA/隧道），
  `ScanTcpPort` 按 64 台一批、每批 400ms 并发探测（/24 约 1.6 秒），命中后同样 `adb connect` + 验状态。
  受 `settings.scanSubnet`（默认 `true`）控制；跨网段/NAT 找不到是预期行为。
- **断开无线会话**：`RunAction("disconnect")` 对该行实际的 `Tls` / `Tcp5555` 端点逐个 `disconnect`，
  并 `SuppressWireless` 10 分钟；不能用 `Preferred` 代替（USB 优先时它可能是 USB 串号）。
- 单测只覆盖纯解析（`WirelessDiscoveryTests` 四条：真实广播行、忽略配对/其他服务、去重与坏行、完整服务名/空输出）；
  真实 mDNS→connect→`device` 的链路靠 `--selftest` 与真机验证。

### 投屏目标必须是 adb 的「传输名」，不是设备串号

踩过的大坑：行对象的 `Key` 是**设备身份**（`getprop ro.serialno`），但 `scrcpy -s` / `adb -s`
只认 adb 当前列出的**传输名**，两者经常不是同一个字符串——

- 无线调试按 mDNS 服务名连接时，adb 里的 serial 是 `adb-<serial>-<hash>._adb-tls-connect._tcp`（**不含冒号**）；
- 走 `adb tcpip` 时是 `ip:5555`。

旧代码用「serial 里没有冒号就是 USB」来判定通道，于是上面第一种被误判成 USB，而 `Key` 随后又被
`ro.serialno` 覆盖掉，最终 `scrcpy -s c0ffee00` 直接报
`ERROR: Could not find ADB device c0ffee00`，窗口永远打不开、页面却一声不响。

现在的规则（改代码时请守住，macOS 见 `Discovery.swift` / `CastManager.swift`，Windows 见 `Services/DiscoveryService.cs` / `Services/CastManager.cs`）：

- 按形状分类传输名，返回 `Kind = usb | tls | tcp5555`，不再只看冒号；
- 行对象里 **`UsbSerial` / `Tls` / `Tcp5555` 存的都是 adb 认的字面传输名**，`Key` 只做身份；
- 任何要拼 `-s` 参数的地方都实时解析目标：用 `adb devices` 的实时结果挑第一个状态为 `device` 的候选，
  全部不通时返回最佳猜测让调用方报错（旧版 PS 里这一步叫 `Resolve-DeviceTarget`）。

### 同一设备重复双击 = 复用窗口（单例）

对同一台设备反复双击只会保留**一个** scrcpy 窗口：第二次起复用已存在的进程并在页面提示"已复用"。
关掉那个 scrcpy 窗口后再双击，会重新投一个新窗口。不同设备之间互不影响，各开各的窗口。
（实现见 `CastManager.swift` 的「Key→子进程 PID」映射，Windows 对应 `Services/CastManager.cs`。）

两个加固点：

- **PID 复用**：只看 PID 是否存活不够，PID 会被别的进程顶掉。所以存活判定还要求进程名仍是 `scrcpy`。
- **跨会话孤儿**：关掉 app 不会杀掉已经开着的投屏窗口，重开 app 后映射是空的。
  认领逻辑（macOS 走 `pgrep -f`、Windows 走 `QueryFullProcessImageName`）会把这个孤儿认领回来，
  避免出现两个 scrcpy 抢同一台设备。真要重开，用右键「强制重新投屏」（`force` 标志）。

### 投屏启动的进度反馈（loading）

scrcpy 从"进程起来"到"窗口出现"还要 1~3 秒（推 scrcpy-server 到手机 → 握手 → 开 SDL 窗口），
这段时间界面上必须有东西在动，否则用户会以为双击没生效，然后狂点——旧版正是这么被玩坏的。

三层反馈（macOS SwiftUI 版；Windows 的 WPF 版是同一套语义的原生实现——行内 `StateText` 变「启动中…」+
右下角 toast 卡片，见 `Views/MainWindow.xaml` 的 `Toast` 与 `MainViewModel` 的 toast 属性）：

1. **行内**：触发的那一行状态列换成转圈 + "启动中…"（`castingKeys` 集合标记，淡蓝底）。
   列表每 10s 整体刷新一次，所以状态放在 `castingKeys` 集合里，刷新重绘据此还原，不会被抹掉。
2. **右下角进度卡片**（`CastToastView` overlay）：转圈 + 主文案 + 设备名 + 实时秒数（"已等待 2.4s"）。
   不用全屏遮罩——它不挡表格，点一下即可关闭。
3. **结果态**：成功 ✓「投屏窗口已打开」（2.2s 淡出）；失败 ✕ 带 scrcpy 原话（8s 淡出，同时横幅保留详情）。

结束时机**不是拍脑袋定死的等待**，而是进程给的真实信号：macOS 走 `DeviceService.castProgress(key:)`
（原 `GET /api/caststate` 语义）返回 `{running, elapsed, ready}`，Windows 直接调 `CastManager` 的同一个判定。
`ready` 由就绪判定逻辑读 scrcpy 捕获日志判断（见 `CastManager.swift` / `Services/CastManager.cs`）——
出现 `[server] INFO: Device:` / `New texture` / `Renderer:` 就说明已连上设备、窗口马上到。
实测：1.5s 时 `ready:false`，2.1s 时 `ready:true`。

兜底（别让用户永远转圈）：`ready` 一直不来时 `elapsed >= 6s` 也算成功；20s 超时只给 warn 不报错；
`running:false` 才是真失败。

并发控制：同一设备重复触发只提示"正在启动中…"，全局同一时刻只处理一次启动（`castBusy`），
避免连点开出多个 scrcpy 抢同一台手机。

投屏启动时会把 scrcpy 的 stdout/stderr 落到临时文件。服务层启动后短暂复查进程还在不在，没了就把日志原文
塞进 `scrcpy_exited` 错误返回给界面。以前这种失败是「返回一个 PID，然后什么都没发生」。

---

## Windows 导航条吸附机制（详解）

> 这套机制在**原生 C#/WPF 版**里（`Services/NavBarLayout.cs` + `NavBarService.cs` + `Views/NavBarWindow.xaml`）。

导航条在 Windows 上**吸附在投屏窗口的下边缘、和窗口同宽**，看起来就像那个窗口自带的一条工具栏。

- **吸附跟随**：拖动 / 缩放 / 最大化投屏窗口，按钮条每 60ms 跟一次坐标（`GetWindowRect` 拿到的是物理像素，
  要除以 WPF 的 DPI 缩放 `PresentationSource.FromVisual(w).CompositionTarget.TransformToDevice.M11`
  才是窗口坐标）。放不下就自动翻到窗口**上沿**；投屏窗口最大化的时候上下都没地方，就叠在画面**底部内侧**。
  投屏窗口最小化，按钮条跟着藏起来（`IsIconic` → `Hide()`），还原后自己回来。
- **拖一下 = 脱离**：按住按钮条空白处拖动，它就不再跟随，变成可以自由摆放的悬浮条（标题会写「悬浮中」）；
  **双击**它重新吸附回去。吸附状态下不显示设备名——投屏窗口自己的标题栏已经写了。
- 点 **✕** 只关按钮条，不影响投屏；投屏窗口一关，按钮条在下一轮跟随（60ms 级）里被收掉——
  按 scrcpy 的 PID 判活，PID 复用另有映像名校验。
- 竖屏手机的窗口窄（一台 1080p 手机投出来大约 490 DIP 宽），七颗按钮会自动折成两行，宽度始终等于投屏窗口宽度。
- 不想要它：主窗口工具条上的 **「导航条」** 开关（`settings.navBar`，缺省为开，老配置文件没这个键也按开处理）。
  关掉只是藏起来，再打开会回到还在投的那几台设备上。
- 只想按一下：右键列表里的设备 → **返回 / 桌面 / 多任务 / 唤醒屏幕**，直接对选中的那台发键，不用开按钮条。

实现上几条不显眼但会咬人的点：

- 纯几何抽成了 `NavBarLayout.Place(mirror, barHeight, work)`（无窗口依赖，单测直接打）：`below` → 下沿 +1px 缝；
  超出工作区 → `above` → 上沿 -h-1；都不行 → `inside` → 叠在底部内侧 `Bottom-h-3`，并且 `y` 兜底不小于工作区顶 +1。
  圆角按贴边方向削平：`below` 只圆下两角、`above` 只圆上两角、`inside` 四角都圆。
- **投屏窗口还没布局过时 `ActualHeight` 是 0**，按 0 算条子会掉到窗口下沿外变成一条线；
  所以高度小于 10 一律按 40 兜底。
- **宽度每轮都要重新赋值**，不能写 `if (Width != mirror.Width)`：一旦切成悬浮态（`SizeToContent.WidthAndHeight`）
  `Width` 就是 `NaN`，差值判断永远为真/假其中一个，回到吸附态就不再跟宽度了。
  另外 `ApplyFloatingStyle()` 里要先把 `Width = double.NaN` 再设 `SizeToContent`，顺序反了会被忽略。
- `DispatcherTimer` 建了不 `Start()` 就永远不 Tick。
- `DragMove()` 在按钮已经抬起之后调用会抛 `InvalidOperationException`，包一层 try。
- 有一处**刻意设计**：叠在画面内侧（`inside`，即投屏窗口最大化）时保持 `Topmost=true`，
  否则按钮条会跑到 scrcpy 的 SDL 窗口底下看不见；其余状态下不置顶，免得跟着满屏跑压住别的窗口。
- 主窗口关闭时导航条也是窗口，`Application` 的 `ShutdownMode` 必须是 `OnMainWindowClose`，
  否则关主窗口后进程被导航条留着（幽灵进程）。
- 无边框自绘：`WindowStyle=None` + `AllowsTransparency=True` + `ShowActivated=False`
  （点按钮条不该抢走投屏窗口的焦点）。

按键走 `adb -s <传输名> shell input keyevent <码>`（返回 4 / 桌面 3 / 多任务 187 / 音量- 25 / 音量+ 24 /
息屏 223 / 唤醒 224），不依赖 scrcpy 窗口是否在前台。在一台三键导航手机上实测过：三颗键都是
**从电脑发出、经 Wi-Fi 送达、手机真的响应**——先打开设置页，按键后前台窗口 `mCurrentFocus` 从
`com.android.settings` 变成 launcher；返回键连按三次能把叠了几层的设置页一层层退到桌面。
> 这套机制的自动化覆盖在 `smoke-ui.ps1 -Scenario Device`，见下文。

---

## Windows C# / WPF 版实现要点（2026-10-11 重写）

- **工程与包**：`net8.0-windows` + `UseWPF`；界面用 [WPF-UI](https://github.com/lepoco/wpfui) 4.3.0
  （`ui:FluentWindow` / `TitleBar` / `InfoBar` / `Card` / `TextBox` / `ToggleSwitch` + Mica 背景），
  MVVM 用 CommunityToolkit.Mvvm 8.4.2，WMI 查进程映像用 System.Management 8.0.0。
- **源生成器的命名**：`[ObservableProperty]` 生成的属性名用的是**字段名原样**，`[RelayCommand]` 作用在
  `XxxAsync` 上生成的是 `XxxCommand`。写 XAML 绑定前先确认生成出来的成员叫什么，别按直觉猜。
- **单文件发布**：`PublishSingleFile` 之外还要 `IncludeNativeLibrariesForSelfExtract`——不加它，WPF 会往
  exe 旁边甩 5 个原生 dll；再加 `EnableCompressionInSingleFile` 才是一个 74 MB 的文件。
  `AppContext.BaseDirectory` 在单文件下**仍然返回 exe 的真实所在目录**，所以 `<exeDir>\tools` 这套约定不用改。
- **服务层是从 Go 版逐条对照移植的**（Go 版源码已删，行为清单在 git 历史里）：8 秒搜索预算、盘根往下 3 层、
  10 秒定时刷新、就绪判定的四条日志 pattern、`-no-scan` / `--selftest` 语义都写进了单测。
  有几处**刻意保持与 Go 一致的"不完美"**（例如工具目录去重只做 TrimSpace + 忽略大小写，不折叠结尾分隔符），
  注释里点明了，别顺手"优化"掉——两端行为一致比单端好看更重要。
- **UI Automation 冒烟（`tools/smoke-ui.ps1`）踩到的坑**，都是量出来的：
  - PS 5.1 下 `[AutomationElement]::TrueCondition` 绑成 `$null`，`FindAll` 直接抛"值不能为 null"
    → 只能用 `TreeWalker` + `ControlViewWalker` 自己 BFS。
  - `ui:Card` / `ui:InfoBar` 这两个容器**根本不出现在 UIA 控制视图里**，挂在它们身上的 AutomationId 拿不到；
    能拿到的是里面的子控件（工具目录输入框 + 三个按钮）和 InfoBar 自己的关闭按钮（固定 id `CloseButton`）。
    所以"面板有没有显示"这类断言打在子元素上。
  - **WPF 的 ContextMenu 弹窗在 UIA 树里挂在主窗口下面**，不是桌面的另一个子窗口。用 `probe-menu.ps1` 量的：
    右键前主窗口子树 0 个 `MenuItem`、右键后 11 个；同时 Win32 侧确实多出一个可见的
    `HwndWrapper[ScrcpyPicker;;<guid>]` 顶层窗口。照着"弹窗一定是独立顶层窗口"去扫桌面，就会永远扫到 0 个。
  - 虚拟化 DataGrid 的行会报一个**比窗口还宽**的 `BoundingRectangle`（它按整个可滚动区域算），
    点击点要取「行矩形 ∩ 窗口矩形」的中心；窗口悬出虚拟桌面时先 `MoveWindow` 拉回来，
    否则 `SetCursorPos` 被夹到边界、点击落到别的窗口上（表现就是"右键没反应"）。
  - `mouse_event` 合成的右键**能**触发 WPF 的 `ContextMenuOpening`，`e.OriginalSource` 正常落在行内元素上，
    所以菜单点不出来一般是上面两条坐标/树的问题，不是"合成消息 WPF 不认"。
  - 空单元格在 UIA 里的 Name 不是空串，而是 WPF 的兜底格式「项: {类型}，列显示索引: N」
    —— 别把它当成"绑定坏了"。
  - PS 函数 `return , $list` 会让调用方收到"一个元素，内容是整个 List"；`@(Get-Xxx)` 包一层 + 函数里返回裸
    `$found` 才对。返回两个值会被解构成"类型不匹配"，要往调用方带附加信息就用一个 `List[string]` 出参。
    同一个坑在导航条那批断言里又踩了一次：`@(Get-XamlValue $NavXaml '...')` 数出来是 1，
    加 `| ForEach-Object { $_ }` 才是 8 个。
- **导航条在 UIA 树里的位置**（量的，不是猜的）：按钮条是**同进程的另一个窗口**，挂在桌面（Root）下面、
  与主窗口平级（`ClassName=Window`、`Name=导航键`），所以找它得按 PID 扫桌面子窗口，
  拿主窗口句柄往下 BFS 永远找不到。UIA 的 `BoundingRectangle` 两侧单位一致（冒烟进程本身 DPI-aware，
  报的都是物理像素），"1 DIP 的缝隙"量出来是 1~2 px，容差给 8px 而不是 1px。
  `InvokePattern.Invoke()` 与 z-order 无关，按钮条被投屏窗口压住也能触发，所以不需要真鼠标。
  **息屏那颗（223）在小米/HyperOS 上先落到 `Dozing`（dream 状态）而不是 `Asleep`**，断言两个都要收，
  而且按一次不保证立刻改状态——轮询到第 3 次才按一次才稳。
- **便携 zip**：运行依赖本来就全在发布物里（发布目录只有 exe + pdb，.NET 运行时和 WPF 原生 dll 都压在单文件里，
  adb/scrcpy 及其 dll 走 `Dist\tools`），zip 只是把这一份一次拷走：staging 里 `ScrcpyPicker\ScrcpyPicker.exe` +
  `ScrcpyPicker\tools\*` + `ScrcpyPicker\README.txt`，`ZipFile::CreateFromDirectory` 出 `Dist\ScrcpyPicker-win-x64.zip`。
  包内的说明文件**故意叫 `README.txt` 不叫中文名**——`build.ps1` 是 UTF-8 带 BOM 的脚本，中文**正文**可以写进去
  （PS 5.1 下 `Set-Content -Encoding utf8` 就是带 BOM），但中文**文件名**不能硬写进脚本，换台机器系统码一猜就错。
- **冒烟脚本是纯 ASCII 的**：中文断言（列名、右键菜单条目、在线/离线文案）全部在运行时从 XAML / C# 源码里
  正则现读，界面改了字而脚本没跟着改，会直接报"解析不到"而不是悄悄放过；
  `tools/check-ps1.ps1` 是这套脚本自己的静态闸门（ASCII 字节 + 双解析器 + 定义了却没调用的函数）。

---

## Windows 文件互传实现要点（1.1.0）

移植自 macOS 的 `TransferManager` / `TransferViewModel`，规则相同、线程模型换成 WPF 的 Dispatcher：

- **服务层可无头单测**：`TransferManager` 不依赖 WPF，受理五重判定全部在一把锁内完成
  （adb 已解析 → 行在线 → 每设备互斥 → 全局计数 < 3 → 登记），拒绝式返回、不排队。
  `_rows()` 读的是 `PickerBackend.SnapshotRows()`，与界面看到的是同一份行快照。
- **目标严格 live-only**：`TransferTargets.ChooseLive` 只接受 `adb devices` 当前状态为 `device` 的候选，
  一个都没有就返回 null；这里**不能**复用投屏的 `ResolveTarget` 兜底逻辑，否则设备掉线会被错报成别的失败。
- **进度必须实测**：adb 的输出被管道接走时不会打印 `[%]`，所以推送看设备端（文件 `stat -c %s`、
  文件夹 `du -sk`），拉取看本机落地目录递归大小。测不到总字节就不启动轮询，卡片显示「传输中…」；
  轮询本身失败只影响那一拍，不能打断传输。
- **回调线程**：`TransferManager.ProgressChanged / FinalChanged` 在后台线程触发，`TransferCenter`
  统一 `Dispatcher.BeginInvoke` 回 UI 线程；关窗后 Dispatcher 已停，迟到的回调直接丢弃。
- **取消/清理**：`Cancel` 只置标志并杀本次 adb 进程，执行器在进程退出后删设备端半包（推送）
  或本次新建的落地目录（拉取）；关主窗口走 `CancelAll`，不留孤儿。
- **行内状态优先级**：`DeviceItem.StateText` = 启动中… > 传输中 > 离线 / 在线；
  列表每 10 秒整体重建，所以「传输中」也必须像 `_casting` 一样由集合按 Key 贴回。
- **右键菜单与冒烟脚本的契约**：传输两项直接构造 `MenuItem`，没有写成 `Add(menu, "...")`，
  这样 `smoke-ui.ps1` 的「离线菜单恰好三项」断言仍然成立；离线行本来就不进 `if (!item.IsOffline)` 分支。
- **文件选择框的差异**：WPF 的 `OpenFileDialog` 只能混选文件，文件夹推送走拖放
  （macOS 的 NSOpenPanel 可以两者混选）。下载目录读 Windows known folder，OneDrive 重定向也认，
  `SCRCPY_DOWNLOAD_DIR` 仅用于测试覆盖。

---

## Swift 实现与打包踩坑

- `swiftc` 多文件编译时，top-level 语句（`let app = NSApplication.shared` 之类）**只允许出现在 `main.swift`**，
  其余文件只能是声明。所以入口被抽进 `main.swift`，逻辑放在 `ScrcpyPicker.swift` / `NavBar.swift`。
- 服务跑在**窗口进程内**的主线程之外；app 退出要显式停掉刷新线程
  （`DeviceService.stopRefreshLoop()`，`windowWillClose` 与 `applicationWillTerminate` 双入口幂等）。
- **备注名被刷新冲掉的坑**：设备行第一轮是以 adb 传输名为 Key 建起来的
  （无线调试时是 `adb-c0ffee00-xxx._adb-tls-connect._tcp`），拿到 `ro.serialno` 后 Key 才被换成真串号
  `c0ffee00`。备注名按真串号存，下一轮刷新时若又用传输名建行，就会把备注名覆盖成空。
  修法：建行时就用缓存里的 `Alias` 回填，且**换 Key 时把旧 Key 的缓存（含 Alias）迁到新 Key**。
  Windows 端因为 USB 场景下传输名恰好等于串号，所以一直没暴露。C#/WPF 版按同一套修法移植
  （`DiscoveryService` 的 Remember / 换 Key 迁移），并有对应单测兜住。

---

## 已知限制

- 设备发现只覆盖**本机所在的那个 /24**，跨网段或隔 VLAN 就找不到（这是有意的，避免全网广播式扫描）。
- 未做：给老设备自动执行 `adb tcpip 5555` 的开机脚本方案；投屏窗口的画质/码率仍是命令行里写死的
  `-m 1280 -b 4M --max-fps=60`，没做成界面可调。
- **Windows C#/WPF 版目前只做到这些程度的自动化验证**（2026-10-22）：124 个服务层/几何单测、`--selftest` 无头冒烟、
  `smoke-ui.ps1` 的四个 UI Automation 场景（工具齐全 / 缺工具 / 离线缓存行 / 真机右键菜单 + 双击真的拉起 scrcpy；
  真机场景里还查导航条：八颗按钮都在、条宽 = 窗口宽、下沿缝 1px、挪窗口后仍贴住、息屏/唤醒真的改了
  `dumpsys power` 的 `mWakefulness`、投屏进程死了条子跟着消失）。
  **没有覆盖**：深度刷新的子网 5555 命中（台架上的设备都走 mDNS/TLS，没有开 5555 的机器）、设置备注名的输入框、**音量± 两颗键的效果**
  （设备侧没有好观测的读数，只验到按钮在、点得动）、Mica 视觉与托盘缺失下的观感。
  无线链路已验到真机：`--selftest` 在手动 `adb disconnect` 后自动重连并落成「无线调试」行；
  `smoke-ui.ps1` 的 Healthy 场景从空缓存发现该行、状态栏为「无线/扫描：开启」，Device 场景用这条无线通道
  拉起 scrcpy 并验导航条。「断开无线会话」的 10 分钟抑制另用一次性 UI Automation 脚本验过：
  点完端点消失，等过一轮 10 秒自动刷新也没有被拉回来（脚本未入库）。
  文件互传只覆盖了纯逻辑（候选通道、失败映射、落地命名、字节测量、受理拒绝分支）；
  **真机推送/拉取、拖放、取消与半包清理没有自动化覆盖**，需要台架上手验。
  前几项要么需要在手机上点配对界面（由人来做），要么只有代码级/单测级保证。
- 导航条的**鼠标手势**没有自动化覆盖：真鼠标点击、按住拖动脱离吸附、双击重新吸附——冒烟里是用
  `InvokePattern.Invoke()` 按 AutomationId 触发按钮（等价于按下，但不走鼠标路径），跟随是用 `MoveWindow`
  挪投屏窗口验证的（不走拖动）。吸附只跟**同一个进程**的窗口：如果 scrcpy 是被别的壳（比如 `cmd /c start`）
  拉起来的，PID 对不上就退化成悬浮条。macOS 版则是独立浮动 HUD，不做窗口吸附（那要 Accessibility 权限）。
