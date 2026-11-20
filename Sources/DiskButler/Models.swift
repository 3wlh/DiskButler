import Foundation

/// 回挂配置中的一条登记：名称|UUID|UID:GID
struct ConfEntry: Identifiable, Hashable {
    var label: String
    var uuid: String
    var owner: String
    var id: String { uuid }
}

/// 菜单里展示的一个卷（已挂载的外置卷，或已登记但未插的卷）
struct Volume: Identifiable {
    var name: String
    var mountPoint: String
    var uuid: String
    var deviceNode: String
    var fileSystem: String
    var mounted: Bool
    var hidden: Bool
    var ownedByMe: Bool
    var registered: Bool
    /// 以 nobrowse 挂载：卷不出现在桌面和访达侧边栏（只能从 /Volumes 路径进入）
    var nobrowse: Bool = false

    var id: String { uuid.isEmpty ? mountPoint : uuid }

    /// BSD 标志只有 APFS / HFS+ 支持，exFAT / FAT32 不支持
    var supportsFlags: Bool {
        let fs = fileSystem.lowercased()
        return fs == "apfs" || fs == "hfs"
    }

    var subtitle: String {
        var parts: [String] = []
        if mounted {
            parts.append(fileSystem.isEmpty ? "已挂载" : fileSystem.uppercased())
            if hidden { parts.append("桌面图标已隐藏") }
            if nobrowse { parts.append("访达中已隐藏") }
        } else {
            // 设备整个不见了（Finder 推出/拔掉）：只能等重插，守护无法凭空挂回
            parts.append(deviceNode.isEmpty ? "设备未连接" : "未挂载")
        }
        if registered { parts.append("已登记") }
        return parts.joined(separator: " · ")
    }
}
