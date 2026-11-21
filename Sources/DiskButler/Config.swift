import Foundation

/// 全部配置集中保存为一个 JSON：/Library/Application Support/DiskButler/DiskButler.json
/// 目录由守护/安装脚本创建并交给登录用户：App（普通用户）与 root 守护都能读写
struct DiskConfig: Codable, Equatable {
    /// 一个登记卷的全部配置
    struct Volume: Codable, Equatable {
        var label: String
        var uuid: String
        /// 以 nobrowse 挂载（不在桌面和访达显示）
        var nobrowse: Bool = false
        /// 最近一次创建的入口位置（原始值，可含 ~）；空表示还没创建
        var entryPath: String = ""
        /// 在访达里阻止推出
        var protectEject: Bool = true

        init(label: String, uuid: String, nobrowse: Bool = false,
             entryPath: String = "", protectEject: Bool = true) {
            self.label = label
            self.uuid = uuid
            self.nobrowse = nobrowse
            self.entryPath = entryPath
            self.protectEject = protectEject
        }

        private enum CodingKeys: String, CodingKey {
            case label, uuid, nobrowse, entryPath, protectEject
            // 旧版字段：只用于读取时迁移
            case entryLink
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            uuid = try c.decodeIfPresent(String.self, forKey: .uuid) ?? ""
            nobrowse = try c.decodeIfPresent(Bool.self, forKey: .nobrowse) ?? false
            entryPath = try c.decodeIfPresent(String.self, forKey: .entryPath) ?? ""
            protectEject = try c.decodeIfPresent(Bool.self, forKey: .protectEject) ?? true
            // 旧配置把「已创建」单独存在 entryLink，合并成一个字段
            if entryPath.isEmpty,
               let link = try c.decodeIfPresent(String.self, forKey: .entryLink) {
                entryPath = link
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            try c.encode(uuid, forKey: .uuid)
            try c.encode(nobrowse, forKey: .nobrowse)
            try c.encode(entryPath, forKey: .entryPath)
            try c.encode(protectEject, forKey: .protectEject)
        }
    }

    /// 内存盘（tmpfs）的全部配置
    struct Memory: Codable, Equatable {
        /// 大小（GB）
        var sizeGB: Int?
        /// 开机是否自动创建
        var autoCreate: Bool?
        /// 内存盘目录 → 链接位置
        var links: [Link]?

        init(sizeGB: Int? = nil, autoCreate: Bool? = nil, links: [Link]? = nil) {
            self.sizeGB = sizeGB
            self.autoCreate = autoCreate
            self.links = links
        }
    }

    struct Link: Codable, Equatable {
        var dir: String
        var target: String
    }

    /// 登记回挂的卷：nobrowse、入口、防止推出都跟着各自的卷
    var volumes: [Volume] = []
    /// 内存盘配置
    var memory: Memory?
    /// 待处理的「修复权限」请求（挂载点路径），守护执行后清空
    var fixRequest: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case volumes, memory, fixRequest
        // 旧版顶层字段：只用于读取时迁移
        case nobrowse, protectEject, entryPaths, entryLinks
        case memorySizeGB, memoryAutoCreate, memoryLinks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = try c.decodeIfPresent([Volume].self, forKey: .volumes) ?? []
        memory = try c.decodeIfPresent(Memory.self, forKey: .memory)
        fixRequest = try c.decodeIfPresent(String.self, forKey: .fixRequest)

        // 旧配置迁移：内存盘三个顶层字段合成 memory 块
        if memory == nil {
            let size = try c.decodeIfPresent(Int.self, forKey: .memorySizeGB)
            let auto = try c.decodeIfPresent(Bool.self, forKey: .memoryAutoCreate)
            let links = try c.decodeIfPresent([Link].self, forKey: .memoryLinks)
            if size != nil || auto != nil || links != nil {
                memory = Memory(sizeGB: size, autoCreate: auto, links: links)
            }
        }

        // 旧配置迁移：nobrowse 列表、入口映射、整体防止推出开关折进各卷
        let legacyNobrowse = try c.decodeIfPresent([String].self, forKey: .nobrowse)?
            .map { $0.uppercased() }
        let legacyPaths = try c.decodeIfPresent([String: String].self, forKey: .entryPaths) ?? [:]
        let legacyLinks = try c.decodeIfPresent([String: String].self, forKey: .entryLinks) ?? [:]
        let legacyProtect = try c.decodeIfPresent(Bool.self, forKey: .protectEject)
        for i in volumes.indices {
            let key = volumes[i].uuid.uppercased()
            if let list = legacyNobrowse {
                volumes[i].nobrowse = list.contains(key)
            }
            if volumes[i].entryPath.isEmpty {
                // 旧配置的「已创建」优先于「配置值」
                volumes[i].entryPath = legacyLinks[key] ?? legacyPaths[key] ?? ""
            }
            if let p = legacyProtect { volumes[i].protectEject = p }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encode(volumes, forKey: .volumes)
        try c.encodeIfPresent(fixRequest, forKey: .fixRequest)
    }
}

/// 系统级自动挂载开关：diskarbitrationd 读这个键决定登录窗口是否挂载硬盘
enum AutoMount {
    static let domain = "/Library/Preferences/SystemConfiguration/autodiskmount"
    static var withoutLogin: Bool {
        guard let d = NSDictionary(contentsOfFile: domain + ".plist") else { return false }
        return (d["AutomountDisksWithoutUserLogin"] as? Bool) ?? false
    }
}

enum ConfigStore {
    static let dir = "/Library/Application Support/DiskButler"
    static let path = dir + "/DiskButler.json"
    /// 跨进程读写锁：App 与 root 守护都会改这份 JSON，读-改-写必须串行，否则互相覆盖
    private static let lockPath = dir + "/.lock"
    /// 旧位置（/Users/Shared），仅用于迁移
    static let legacyPath = "/Users/Shared/DiskButler.json"

    static func read() -> DiskConfig {
        let fm = FileManager.default
        if let data = fm.contents(atPath: path),
           let c = try? JSONDecoder().decode(DiskConfig.self, from: data) {
            return c
        }
        // 新位置还没有时读旧配置；守护启动后会把它迁移过来
        if let data = fm.contents(atPath: legacyPath),
           let c = try? JSONDecoder().decode(DiskConfig.self, from: data) {
            return c
        }
        let c = DiskConfig()
        write(c)
        return c
    }

    static func write(_ c: DiskConfig) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = encode(c).data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        handToConsoleUser()
    }

    /// 手写序列化：JSONEncoder 不保证键顺序，这里固定成便于阅读的顺序
    private static func encode(_ c: DiskConfig) -> String {
        var sections: [String] = []

        if let m = c.memory {
            var lines = ["    \"memory\" : {"]
            var fields: [String] = []
            if let gb = m.sizeGB { fields.append("        \"sizeGB\" : \(gb)") }
            if let auto = m.autoCreate { fields.append("        \"autoCreate\" : \(auto)") }
            if let links = m.links {
                if links.isEmpty {
                    fields.append("        \"links\" : []")
                } else {
                    let items = links.map {
                        "            {\n                \"dir\" : \(quote($0.dir)),\n                \"target\" : \(quote($0.target))\n            }"
                    }
                    fields.append("        \"links\" : [\n" + items.joined(separator: ",\n") + "\n        ]")
                }
            }
            lines.append(fields.joined(separator: ",\n"))
            lines.append("    }")
            sections.append(lines.joined(separator: "\n"))
        }

        if c.volumes.isEmpty {
            sections.append("    \"volumes\" : []")
        } else {
            let items = c.volumes.map { v in
                [
                    "        {",
                    "            \"label\" : \(quote(v.label)),",
                    "            \"uuid\" : \(quote(v.uuid)),",
                    "            \"nobrowse\" : \(v.nobrowse),",
                    "            \"entryPath\" : \(quote(v.entryPath)),",
                    "            \"protectEject\" : \(v.protectEject)",
                    "        }"
                ].joined(separator: "\n")
            }
            sections.append("    \"volumes\" : [\n" + items.joined(separator: ",\n") + "\n    ]")
        }

        if let fix = c.fixRequest {
            sections.append("    \"fixRequest\" : \(quote(fix))")
        }

        return "{\n" + sections.joined(separator: ",\n") + "\n}\n"
    }

    /// JSON 字符串字面量（处理引号、反斜杠与控制字符）
    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }

    /// root 写过的文件普通用户改不动（rename 也被拒），
    /// 表现为「设置改一下就自己弹回去」。所以 root 写完立刻把属主交还登录用户。
    static func handToConsoleUser() {
        guard geteuid() == 0 else { return }
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return }
        _ = chown(dir, st.st_uid, st.st_gid)
        _ = chown(path, st.st_uid, st.st_gid)
        _ = chown(lockPath, st.st_uid, st.st_gid)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }

    static func update(_ mutate: (inout DiskConfig) -> Void) {
        locked {
            var c = read()
            mutate(&c)
            write(c)
        }
    }

    /// flock 对整个读-改-写加排他锁；锁文件本身不需要内容，只作为同步点
    private static func locked<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return body()
    }
}

/// 「防止推出」的 15 秒放行窗口：用标记文件的修改时间表示，不写进配置文件
enum Bypass {
    static let path = ConfigStore.dir + "/.bypass"

    static func mark() {
        try? Data().write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static var active: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) < 15
    }
}

/// nobrowse 卷的入口链接：App 手动创建与守护回挂共用同一套位置与去重逻辑
enum EntryLinks {
    static func raw(uuid: String, label: String, config: DiskConfig) -> String {
        let custom = config.volumes.first { $0.uuid.uppercased() == uuid.uppercased() }?.entryPath ?? ""
        return custom.isEmpty ? "~/\(label)" : custom
    }

    private static func expand(_ raw: String, home: String) -> String {
        raw.hasPrefix("~") ? home + String(raw.dropFirst()) : raw
    }

    /// 确保入口指向当前挂载点；位置改过时删掉旧入口。真实文件/目录、指向别处的链接都不覆盖。
    static func ensure(uuid: String, label: String, mountPoint: String, home: String) {
        guard !mountPoint.isEmpty else { return }
        let key = uuid.uppercased()
        let cfg = ConfigStore.read()
        let raw = raw(uuid: key, label: label, config: cfg)
        let path = expand(raw, home: home)
        guard !path.isEmpty, path != "/" else { return }
        let fm = FileManager.default

        let oldRaw = cfg.volumes.first { $0.uuid.uppercased() == key }?.entryPath ?? ""
        if !oldRaw.isEmpty {
            let oldPath = expand(oldRaw, home: home)
            if oldPath != path,
               let dest = try? fm.destinationOfSymbolicLink(atPath: oldPath), dest == mountPoint {
                try? fm.removeItem(atPath: oldPath)
            }
        }

        if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
            guard dest == mountPoint else { return }
        } else if fm.fileExists(atPath: path) {
            return
        } else {
            do {
                try fm.createSymbolicLink(atPath: path, withDestinationPath: mountPoint)
            } catch {
                return
            }
        }
        ConfigStore.update { c in
            if let i = c.volumes.firstIndex(where: { $0.uuid.uppercased() == key }) {
                c.volumes[i].entryPath = raw
            }
        }
    }
}
