import Foundation

/// 统一后台服务：同一份二进制以 --daemon（系统守护，登录前就运行）/ --login（登录代理）启动，
/// 不再生成任何 shell 脚本；一个「安装服务」同时负责内存盘开机挂载与硬盘回挂
enum ServiceInstaller {
    static let daemonLabel = "com.local.diskbutler.daemon"
    static let loginLabel = "com.local.diskbutler.login"
    static let uiLabel = "com.local.diskbutler.ui"
    static let daemonPlist = "/Library/LaunchDaemons/\(daemonLabel).plist"
    static let loginPlist = "/Library/LaunchAgents/\(loginLabel).plist"
    /// 旧版「登录后自动打开菜单栏 App」的残留文件，安装时清理
    static let uiPlist = "/Library/LaunchAgents/\(uiLabel).plist"
    /// 守护逻辑版本：plist 里带这个标记，二进制行为升级后界面才会提示「升级」
    static let daemonVersion = 8

    static var binaryPath: String {
        Bundle.main.executablePath ?? "/Applications/DiskButler.app/Contents/MacOS/DiskButler"
    }

    static var installed: Bool {
        FileManager.default.fileExists(atPath: daemonPlist)
    }

    /// 旧版登录代理还在，或新 plist 没指向二进制 → 需要（重）装
    static var needsUpgrade: Bool {
        // 旧版残留：登录代理 / UI 代理（现在开机只跑守护，GUI 由用户按需打开）
        if FileManager.default.fileExists(atPath: loginPlist)
            || FileManager.default.fileExists(atPath: uiPlist) { return true }
        guard let text = try? String(contentsOfFile: daemonPlist, encoding: .utf8) else { return false }
        if !text.contains("--daemon") || !text.contains("KeepAlive") { return true }
        return !text.contains("DiskButlerDaemonVersion: \(daemonVersion)")
    }

    // MARK: - 安装 / 卸载

    static func install() throws {
        let bin = xmlEscape(binaryPath)
        let daemonPlistText = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <!-- DiskButlerDaemonVersion: \(daemonVersion) -->
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(bin)</string>
                <string>--daemon</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
        let stage = "/tmp/diskbutler-stage-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: stage, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: stage) }
        for (name, text) in [("daemon.plist", daemonPlistText)] {
            try text.write(toFile: "\(stage)/\(name)", atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(stage)/\(name)")
        }

        let script = """
        set -e
        UID_NOW=\(getuid())
        mkdir -p \(shq(ConfigStore.dir))
        chown \(getuid()):\(getgid()) \(shq(ConfigStore.dir))
        if [ -f \(shq(ConfigStore.legacyPath)) ] && [ ! -f \(shq(ConfigStore.path)) ]; then
            mv \(shq(ConfigStore.legacyPath)) \(shq(ConfigStore.path))
        fi
        chown \(getuid()):\(getgid()) \(shq(ConfigStore.path)) 2>/dev/null || true
        install -o root -g wheel -m 644 \(shq(stage + "/daemon.plist")) \(shq(daemonPlist))
        launchctl bootout system/\(daemonLabel) 2>/dev/null || true
        launchctl bootstrap system \(shq(daemonPlist)) 2>/dev/null || launchctl load -w \(shq(daemonPlist)) || true
        # 登录代理 / UI 代理已取消（开机只跑守护，界面由用户按需打开）
        launchctl bootout gui/${UID_NOW}/\(loginLabel) 2>/dev/null || true
        launchctl bootout gui/${UID_NOW}/\(uiLabel) 2>/dev/null || true
        rm -f \(shq(loginPlist)) \(shq(uiPlist))
        """

        // 只有一条提权通道，避免弹两次授权框
        _ = try PrivilegedRunner.run(script)
        guard fm.fileExists(atPath: daemonPlist) else {
            throw ButlerError.message("安装失败：没有权限写入 \(daemonPlist)")
        }
    }

    static func uninstall() throws {
        _ = try PrivilegedRunner.run(
            """
            UID_NOW=\(getuid())
            launchctl bootout system/\(daemonLabel) 2>/dev/null || true
            launchctl bootout gui/\(getuid())/\(loginLabel) 2>/dev/null || true
            launchctl bootout gui/\(getuid())/\(uiLabel) 2>/dev/null || true
            rm -f \(shq(daemonPlist)) \(shq(loginPlist)) \(shq(uiPlist))
            exit 0
            """
        )
        // 脚本即使没权限也可能以 0 退出，这里核实结果
        if FileManager.default.fileExists(atPath: daemonPlist) {
            throw ButlerError.message("卸载失败：没有删除 \(daemonPlist)（提权未生效）")
        }
    }

    /// 未安装服务时：直接提权修改系统级「未登录自动挂载」设置
    static func setAutoMount(_ on: Bool) throws {
        _ = try PrivilegedRunner.run(
            "/usr/bin/defaults write \(shq(AutoMount.domain)) AutomountDisksWithoutUserLogin -bool \(on ? "true" : "false")"
        )
    }

    // MARK: - 修复权限

    /// 服务已安装：交给 root 守护做（它不受 App 的 TCC 归属限制，改动可移动卷不会被拒）
    /// 未安装：退回直接提权 chown
    static func fixOwner(mountPoint: String) throws -> String? {
        if installed {
            Daemon.requestFix(mountPoint)
            Thread.sleep(forTimeInterval: 1.5)
            let owner = Shell.out("/usr/bin/stat", ["-f", "%u", mountPoint])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if owner == "\(getuid())" { return nil }
            return "系统拒绝了属主修改（后台服务被 TCC 拦截）。\n请到 系统设置 → 隐私与安全性 → 完全磁盘访问权限，点 + 添加 /Applications/DiskButler.app 并勾选，然后重试。"
        }
        let owner = "\(getuid()):\(getgid())"
        let out = try PrivilegedRunner.run(
            """
            MP=\(shq(mountPoint))
            TARGET=\(owner)
            FAILED=""
            fix() {
                CUR=$(/usr/bin/stat -f %u:%g "$1" 2>/dev/null)
                [ "$CUR" = "$TARGET" ] && return 0
                ERR=$(/usr/sbin/chown "$TARGET" "$1" 2>&1) || FAILED="$FAILED$ERR\\n"
            }
            fix "$MP"
            for D in "$MP"/*; do
                [ -d "$D" ] || continue
                [ "$(/usr/bin/stat -f %u "$D" 2>/dev/null)" = "0" ] || continue
                fix "$D"
            done
            [ -n "$FAILED" ] && printf '%s' "$FAILED"
            exit 0
            """
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        return "属主交还被系统拒绝：\n\(out)\n请到 系统设置 → 隐私与安全性 → 完全磁盘访问权限，添加并勾选 /Applications/DiskButler.app 后重试。"
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
