; ============================================================
;  Setup.iss - Inno Setup 6 脚本（ScrcpyPicker C#/WPF 单文件 exe 版）
;  准备: 先运行 build.ps1 生成 Dist\ScrcpyPicker.exe 与 Dist\tools\*
;        再把 Dist 下的 ScrcpyPicker.exe 与 tools\ 软链/复制到 staging\
;  构建: ISCC.exe Setup.iss   ->  ..\dist\ScrcpyPicker-Setup-x64.exe
; ============================================================

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName=Scrcpy 设备选择器
AppVersion=1.0.0
AppPublisher=souvenirding
DefaultDirName={autopf}\ScrcpyPicker
DefaultGroupName=ScrcpyPicker
OutputDir=..\dist
OutputBaseFilename=ScrcpyPicker-Setup-x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=admin
SetupIconFile=..\..\assets\picker.ico
UninstallDisplayIcon={app}\picker.ico
WizardStyle=modern

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; 单文件 exe（.NET 8 运行时 + WPF 原生 dll 都在包里，无需 PowerShell / 浏览器 / 另装 .NET）
Source: "staging\ScrcpyPicker.exe"; DestDir: "{app}"; Flags: ignoreversion
; adb + scrcpy（Windows 版，需自行放入 staging\tools）
Source: "staging\tools\*"; DestDir: "{app}\tools"; Flags: recursesubdirs createallsubdirs ignoreversion
; 图标
Source: "..\..\assets\picker.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Scrcpy 设备选择器"; Filename: "{app}\ScrcpyPicker.exe"; IconFilename: "{app}\picker.ico"
Name: "{commondesktop}\Scrcpy 设备选择器"; Filename: "{app}\ScrcpyPicker.exe"; IconFilename: "{app}\picker.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\ScrcpyPicker.exe"; Description: "{cm:LaunchProgram,Scrcpy 设备选择器}"; Flags: nowait postinstall skipifsilent

; 配置写在 %APPDATA%\ScrcpyPicker，卸载时保留用户数据（备注名 / 历史设备）。
