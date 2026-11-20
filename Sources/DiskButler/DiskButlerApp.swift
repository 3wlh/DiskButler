import SwiftUI
import AppKit

struct DiskButlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // 主窗口：启动时不自动弹出（登录自启只留菜单栏图标），
        // 需要时通过菜单栏图标 →「打开 DiskButler」打开
        Window("DiskButler", id: "main") {
            MenuBarView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // 菜单栏图标：点开是菜单，选「打开 DiskButler」进主窗口（不再弹面板）
        MenuBarExtra {
            Button("打开 DiskButler") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("退出 DiskButler") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "externaldrive.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 无 Dock 图标，但启动时把窗口提到最前
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
}
