import SwiftUI
import AppKit

struct DiskButlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        // 非常驻：由用户在终端执行 open -a DiskButler 打开，关闭窗口即退出；后台只留 root 守护
        Window("DiskButler", id: "main") {
            MenuBarView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
}

/// 无 Dock 图标、无菜单栏图标，仅在被手动打开时显示窗口
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 旧版本留下的「登录后打开面板」LaunchAgent：开关已移除，顺手清理
        let legacy = NSHomeDirectory() + "/Library/LaunchAgents/com.local.diskbutler.plist"
        if FileManager.default.fileExists(atPath: legacy) {
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/com.local.diskbutler"])
            try? FileManager.default.removeItem(atPath: legacy)
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉窗口就退出，不留常驻进程
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 再次从终端 open 时，把已存在（最小化/隐藏）的窗口拿回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows { window.makeKeyAndOrderFront(nil) }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
