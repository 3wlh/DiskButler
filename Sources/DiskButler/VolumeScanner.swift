import Foundation

/// 用 diskutil 枚举外置卷，并与回挂配置合并
enum VolumeScanner {
    static func scan(conf: [ConfEntry]) -> [Volume] {
        var volumes: [Volume] = []
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []

        for name in names.sorted() {
            let mp = "/Volumes/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: mp, isDirectory: &isDir), isDir.boolValue else { continue }
            // 内存盘由内存盘分区单独展示
            if mp == MemoryDisk.mountPoint { continue }
            // 排除自身的工作盘判断：只接受外置磁盘
            guard let info = plist(mp), isExternal(info) else { continue }
            // /Volumes 下可能残留同名普通目录（旧的挂载点），它不是卷，跳过
            guard mountPoint(info) == mp else { continue }
            let uuid = ConfStore.cleanUUID((info["VolumeUUID"] as? String) ?? "")
            volumes.append(makeVolume(
                name: (info["VolumeName"] as? String) ?? name,
                mountPoint: mp,
                uuid: uuid,
                deviceNode: (info["DeviceNode"] as? String) ?? "",
                fileSystem: (info["FilesystemType"] as? String) ?? "",
                mounted: isMounted(info),
                nobrowse: isMounted(info) && isNobrowse(mp),
                registered: conf.contains { $0.uuid == uuid }
            ))
        }

        // 已登记但当前不在场的卷（拔掉/未挂载），也列出来，方便取消登记
        for entry in conf where !volumes.contains(where: { $0.uuid == entry.uuid }) {
            let persisted = persistedNobrowse()
            guard let info = plist(entry.uuid) else {
                // 设备整个不在（拔掉/已推出）：仍要列出来，否则用户没法取消登记
                volumes.append(Volume(name: entry.label, mountPoint: "", uuid: entry.uuid,
                                      deviceNode: "", fileSystem: "", mounted: false,
                                      hidden: false, ownedByMe: false, registered: true,
                                      nobrowse: persisted.contains(entry.uuid.uppercased())))
                continue
            }
            volumes.append(makeVolume(
                name: entry.label,
                mountPoint: (info["MountPoint"] as? String) ?? "",
                uuid: entry.uuid,
                deviceNode: (info["DeviceNode"] as? String) ?? "",
                fileSystem: (info["FilesystemType"] as? String) ?? "",
                mounted: isMounted(info),
                nobrowse: persisted.contains(entry.uuid.uppercased()),
                registered: true
            ))
        }
        return volumes
    }

    private static func makeVolume(name: String, mountPoint: String, uuid: String,
                                   deviceNode: String, fileSystem: String,
                                   mounted: Bool, nobrowse: Bool = false,
                                   registered: Bool) -> Volume {
        let hidden = mounted ? isHidden(mountPoint) : false
        let owned = mounted && ownerUID(mountPoint) == getuid()
        return Volume(name: name, mountPoint: mountPoint, uuid: uuid,
                      deviceNode: deviceNode, fileSystem: fileSystem,
                      mounted: mounted, hidden: hidden, ownedByMe: owned,
                      registered: registered, nobrowse: nobrowse)
    }

    /// nobrowse 的持久偏好（记在同一个 JSON 配置里）
    static func persistedNobrowse() -> Set<String> {
        Set((ConfigStore.read().nobrowse ?? []).map { $0.uppercased() })
    }

    /// 当前挂载是否带 nobrowse（mount 行里可见）
    static func isNobrowse(_ mp: String) -> Bool {
        Shell.out("/sbin/mount", []).split(separator: "\n").contains {
            $0.contains(" on \(mp) (") && $0.contains("nobrowse")
        }
    }

    // MARK: - diskutil

    /// diskutil info -plist 解析（对象可以是挂载点或 UUID）
    static func plist(_ target: String) -> [String: Any]? {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", target])
        guard r.ok, let data = r.out.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// 外置判定：Internal=No，或总线协议为 USB/雷雳/火线
    private static func isExternal(_ info: [String: Any]) -> Bool {
        if number(info["Internal"]) == 0 { return true }
        let bus = (info["BusProtocol"] as? String) ?? ""
        return bus == "USB" || bus.hasPrefix("Thunderbolt") || bus.hasPrefix("FireWire")
    }

    /// 挂载点（plist 里有非空 MountPoint 才算已挂载）
    static func mountPoint(_ info: [String: Any]) -> String? {
        guard let mp = info["MountPoint"] as? String, !mp.isEmpty else { return nil }
        return mp
    }

    /// 挂载判定：plist 里有非空 MountPoint 即已挂载（新版 diskutil 不再给 Mounted 键）
    static func isMounted(_ info: [String: Any]) -> Bool {
        if let mp = info["MountPoint"] as? String, !mp.isEmpty { return true }
        return number(info["Mounted"]) == 1
    }

    private static func number(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let i = v as? Int { return i }
        if let b = v as? Bool { return b ? 1 : 0 }
        return nil
    }

    // MARK: - 卷状态

    /// hidden 标志：ls -lOd 的权限串后会出现 hidden 字样
    private static func isHidden(_ mp: String) -> Bool {
        Shell.out("/bin/ls", ["-lOd", mp]).contains(" hidden")
    }

    /// stat 的输出带结尾换行，必须连换行一起裁掉，否则 uid_t("501\n") 解析失败被当成 0
    private static func ownerUID(_ path: String) -> uid_t {
        let s = Shell.out("/usr/bin/stat", ["-f", "%u", path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return uid_t(s) ?? 0
    }
}
