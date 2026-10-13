// Toolchain.swift - adb / scrcpy 的定位与调用（原 shared/Discover.ps1 的工具解析部分）
//
// 解析顺序与 PowerShell 版保持一致：
//   1. $SCRCPY_TOOL_DIR（app 启动器设置，或手动覆盖）
//   2. app 包内 Contents/Resources/tools
//   3. PATH（brew 装的 adb/scrcpy）
// 找不到 adb 时置 adbResolved = false —— 绝不能把"路径错"误报成"没设备"。
import Foundation

/// 运行一条外部命令，合并 stdout/stderr（与 PowerShell 的 `2>&1` 一致），按行返回。
@discardableResult
func runCommand(_ exe: String,
                _ args: [String],
                mergeStderr: Bool = true,
                currentDirectory: String? = nil) -> (status: Int32, lines: [String], text: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = args
    if let dir = currentDirectory { proc.currentDirectoryURL = URL(fileURLWithPath: dir) }
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = mergeStderr ? pipe : Pipe()
    do {
        try proc.run()
    } catch {
        return (-1, [], "")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    // PowerShell 版对每行做了 TrimEnd()：adb 的输出常带 \r 和尾部空格。
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: ["\r", " ", "\t"])
    }
    return (proc.terminationStatus, lines, text)
}

final class Toolchain {
    let adbPath: String
    let scrcpyPath: String
    let toolDir: String
    private(set) var adbResolved: Bool

    private init(adb: String, scrcpy: String, toolDir: String, adbResolved: Bool) {
        self.adbPath = adb
        self.scrcpyPath = scrcpy
        self.toolDir = toolDir
        self.adbResolved = adbResolved
    }

    /// 按 1) SCRCPY_TOOL_DIR  2) <resources>/tools  3) PATH 的顺序定位工具。
    static func resolve(resourcesPath: String?) -> Toolchain {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["SCRCPY_TOOL_DIR"], !env.isEmpty {
            candidates.append(env)
        }
        if let res = resourcesPath { candidates.append(res + "/tools") }

        var toolDir = candidates.first ?? (resourcesPath ?? "") + "/tools"
        var adb = ""
        for c in candidates {
            let p = c + "/adb"
            if FileManager.default.isExecutableFile(atPath: p) { adb = p; toolDir = c; break }
        }

        var adbResolved = true
        if adb.isEmpty {
            // 回退到 PATH：brew 装的 adb。仍然找不到才算"未解析"。
            if let found = Toolchain.which("adb") {
                adb = found
                if toolDir.isEmpty { toolDir = (found as NSString).deletingLastPathComponent }
            } else {
                adbResolved = false
                adb = (toolDir as NSString).appendingPathComponent("adb")
            }
        }

        var scrcpy = (toolDir as NSString).appendingPathComponent("scrcpy")
        if !FileManager.default.isExecutableFile(atPath: scrcpy) {
            if let found = Toolchain.which("scrcpy") { scrcpy = found }
        }
        return Toolchain(adb: adb, scrcpy: scrcpy, toolDir: toolDir, adbResolved: adbResolved)
    }

    private static func which(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 调用 adb，返回输出行（stdout+stderr 合并）。
    func adb(_ args: [String]) -> [String] {
        guard adbResolved else { return [] }
        return runCommand(adbPath, args).lines
    }

    func adbText(_ args: [String]) -> String {
        return adb(args).joined(separator: "\n")
    }

    /// 通过 adb shell 取一条属性的值。
    func shellProp(serial: String, _ cmd: String) -> String {
        let out = adb(["-s", serial, "shell", cmd])
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func adbVersion() -> String {
        guard adbResolved else { return "" }
        return adb(["version"]).first ?? ""
    }

    func scrcpyVersion() -> String {
        guard FileManager.default.isExecutableFile(atPath: scrcpyPath) else { return "" }
        return runCommand(scrcpyPath, ["--version"]).lines.first ?? ""
    }
}

// MARK: - 正则小工具

/// 返回整个匹配 + 各捕获组；不匹配返回 nil。
func reGroups(_ pattern: String, _ text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
    var out: [String] = []
    for i in 0..<m.numberOfRanges {
        let r = m.range(at: i)
        out.append(r.location != NSNotFound ? ns.substring(with: r) : "")
    }
    return out
}

func reTest(_ pattern: String, _ text: String) -> Bool {
    return reGroups(pattern, text) != nil
}
