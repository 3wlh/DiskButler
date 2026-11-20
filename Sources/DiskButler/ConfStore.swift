import Foundation

/// 登记卷的读取与写入（实际保存在 ConfigStore 的单一 JSON 里）
enum ConfStore {
    static func load() -> [ConfEntry] {
        ConfigStore.read().volumes.map {
            ConfEntry(label: $0.label, uuid: $0.uuid, owner: $0.owner)
        }
    }

    /// UUID 只保留十六进制与连字符（与脚本里的清洗规则一致）
    static func cleanUUID(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isHexDigit || $0 == "-" })
    }

    /// 写回登记列表（同 UUID 覆盖、改名刷新）；配置在 /Library/Application Support/DiskButler，不需要提权
    static func save(entries: [ConfEntry]) throws {
        var seen = Set<String>()
        var volumes: [DiskConfig.Volume] = []
        for e in entries where !e.uuid.isEmpty && !seen.contains(e.uuid) {
            seen.insert(e.uuid)
            volumes.append(DiskConfig.Volume(
                label: e.label,
                uuid: e.uuid,
                owner: e.owner.isEmpty ? "\(getuid()):\(getgid())" : e.owner
            ))
        }
        ConfigStore.update { $0.volumes = volumes }
    }
}
