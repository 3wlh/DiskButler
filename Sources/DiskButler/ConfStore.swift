import Foundation

/// 登记卷的读取与写入（实际保存在 ConfigStore 的单一 JSON 里）
enum ConfStore {
    static func load() -> [ConfEntry] {
        ConfigStore.read().volumes.map {
            ConfEntry(label: $0.label, uuid: $0.uuid)
        }
    }

    /// UUID 只保留十六进制与连字符（与脚本里的清洗规则一致）
    static func cleanUUID(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isHexDigit || $0 == "-" })
    }
}
