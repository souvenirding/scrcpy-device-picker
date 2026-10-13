// CastManager.swift - scrcpy 进程的启动、复用与存活判定
// （移植自 Server.ps1 的 $script:CastProc / Test-CastAlive 与 Discover.Unix.ps1 的
//   Start-ScrcpyUnix / Find-ScrcpyPidByTarget）
import Foundation
import Darwin

struct CastState {
    var pid: Int32 = 0
    var started: Date?
    var logPath: String = ""
}

final class CastManager {
    private let lock = NSLock()
    private var proc: [String: CastState] = [:]
    let tools: Toolchain

    init(tools: Toolchain) { self.tools = tools }

    // MARK: - 启动参数

    func argList(target: String, noClipboard: Bool) -> [String] {
        // --shortcut-mod 显式写出，保证 Alt+B / Alt+H / Alt+S 在镜像窗口里可用。
        var a = ["-s", target, "-m", "1280", "-b", "4M", "--max-fps=60",
                 "--window-title", target, "--shortcut-mod=lalt,lsuper"]
        if noClipboard { a.append("--no-clipboard-autosync") }
        return a
    }

    /// 启动 scrcpy，把 stdout/stderr 落到文件，用于判断"已连上"和解释失败原因。
    func start(key: String, target: String, noClipboard: Bool) -> (pid: Int32, logPath: String)? {
        let log = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("scrcpy-picker-cast-\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).err")
        FileManager.default.createFile(atPath: log, contents: nil)
        FileManager.default.createFile(atPath: log + ".out", contents: nil)
        guard let errHandle = FileHandle(forWritingAtPath: log),
              let outHandle = FileHandle(forWritingAtPath: log + ".out") else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tools.scrcpyPath)
        p.arguments = argList(target: target, noClipboard: noClipboard)
        p.currentDirectoryURL = URL(fileURLWithPath: tools.toolDir)
        p.standardOutput = outHandle
        p.standardError = errHandle
        do {
            try p.run()
        } catch {
            return nil
        }
        let pid = p.processIdentifier
        lock.lock()
        var st = proc[key] ?? CastState()
        st.pid = pid
        st.started = Date()
        st.logPath = log
        proc[key] = st
        lock.unlock()
        return (pid, log)
    }

    // MARK: - 存活判定

    /// 记录的 PID 只有在"进程存在 **且** 仍然是 scrcpy"时才算在投屏中 ——
    /// 光看进程是否存在会误收一个被回收后又分配给别的程序的 PID。
    func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return CastManager.scrcpyPids().contains(pid)
    }

    /// 认领上一轮 app 遗留的投屏窗口：app 可以退出再启动，而 scrcpy 还活着，
    /// 同一个设备再开一个 scrcpy 会和旧的抢设备。
    func adopt(key: String, target: String) -> Int32? {
        guard let pid = CastManager.findPidByTarget(target), pid > 0 else { return nil }
        lock.lock()
        var st = proc[key] ?? CastState()
        st.pid = pid
        st.started = Date()
        proc[key] = st
        lock.unlock()
        return pid
    }

    func state(for key: String) -> CastState? {
        lock.lock(); defer { lock.unlock() }
        return proc[key]
    }

    func clear(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        proc.removeValue(forKey: key)
    }

    func kill(_ pid: Int32) {
        guard pid > 0 else { return }
        // SIGTERM 前复核身份（M10 纵深防御）：PID 可能已被系统回收并复用给
        // 无关进程，isAlive 按 scrcpy 进程清单核对，不误杀他人；SIGKILL 阶段已有复核。
        guard isAlive(pid) else { return }
        kill_pid(pid, SIGTERM)
        usleep(300_000)
        if isAlive(pid) { kill_pid(pid, SIGKILL) }
    }

    private func kill_pid(_ pid: Int32, _ sig: Int32) {
        _ = Darwin.kill(pid, sig)
    }

    // MARK: - 日志判读

    /// scrcpy 打印这些行代表已经连上设备、窗口马上就到；"进程起来了"≠"正在投屏"。
    func isReady(logPath: String) -> Bool {
        let txt = output(logPath)
        guard !txt.isEmpty else { return false }
        let pats = [#"\[server\] INFO: Device:"#, "New texture", "Renderer:", #"scrcpy \d"#]
        for p in pats where reTest(p, txt) { return true }
        return false
    }

    /// 失败时给用户看的一行摘要（前 8 行非空输出，空白折叠）。
    func logSummary(logPath: String) -> String {
        guard !logPath.isEmpty else { return "" }
        let txt = output(logPath)
        let lines = txt.split(separator: "\n").map { String($0).trimmed() }.filter { !$0.isEmpty }
        return lines.prefix(8).joined(separator: " ")
    }

    private func output(_ logPath: String) -> String {
        var parts: [String] = []
        for p in [logPath, logPath + ".out"] {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let s = String(data: d, encoding: .utf8) { parts.append(s) }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 进程查询

    static func scrcpyPids() -> Set<Int32> {
        let (_, lines, _) = runCommand("/usr/bin/pgrep", ["-x", "scrcpy"])
        var out = Set<Int32>()
        for l in lines {
            if let v = Int32(l.trimmed()) { out.insert(v) }
        }
        return out
    }

    static func findPidByTarget(_ target: String) -> Int32? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pgrep") else { return nil }
        let esc = NSRegularExpression.escapedPattern(for: target)
        let (_, lines, _) = runCommand("/usr/bin/pgrep", ["-f", "scrcpy.*\(esc)"])
        for l in lines {
            if let v = Int32(l.trimmed()), v > 0 { return v }
        }
        return nil
    }
}
