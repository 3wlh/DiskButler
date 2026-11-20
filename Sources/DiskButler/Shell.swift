import Foundation

/// 统一封装子进程调用（同步，输出量小，够用）
enum Shell {
    struct Result {
        var code: Int32
        var out: String
        var err: String
        var ok: Bool { code == 0 }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(code: -1, out: "", err: "无法启动 \(path)：\(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            code: p.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 只要输出，失败也返回空串（用于探测类命令）
    static func out(_ path: String, _ args: [String]) -> String {
        run(path, args).out
    }
}

/// 单引号转义：把任意字符串安全嵌入 shell 脚本
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum ButlerError: LocalizedError {
    case shell(String)
    case canceled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .shell(let s): return s
        case .canceled: return "已取消（未获得管理员授权）"
        case .message(let s): return s
        }
    }
}

/// 提权执行器：写临时脚本 → 在 App 进程内跑 AppleScript 的
/// 「do shell script ... with administrator privileges」→ 核对退出码
/// 关键点：用 NSAppleScript 在本进程执行，而不是 spawn /usr/bin/osascript，
/// 这样系统密码框的归属是 DiskButler（osascript 则会显示成 osascript）。
enum PrivilegedRunner {
    static func run(_ script: String) throws -> String {
        let path = "/tmp/diskbutler-\(UUID().uuidString).sh"
        do {
            try ("#!/bin/bash\n" + script).write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            throw ButlerError.shell("无法写入临时脚本：\(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let source = "do shell script \"/bin/bash \(path)\" with administrator privileges"
        guard let apple = NSAppleScript(source: source) else {
            throw ButlerError.shell("无法创建授权脚本")
        }
        var errInfo: NSDictionary?
        let result = apple.executeAndReturnError(&errInfo)
        if let errInfo {
            let code = (errInfo["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if code == -128 {
                throw ButlerError.canceled
            }
            let detail = ((errInfo["NSAppleScriptErrorMessage"] as? String)
                          ?? (errInfo["NSAppleScriptErrorBriefMessage"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            debugLog("error=\(code) \(detail.prefix(200))")
            throw ButlerError.shell(detail.isEmpty ? "提权执行失败（\(code)）" : detail)
        }
        let out = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("code=0 out=\(out.prefix(200))")
        return out
    }

    /// 提权过程留痕，便于排查（写入 /tmp，普通用户可读）
    private static func debugLog(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        let path = "/tmp/diskbutler-priv.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
