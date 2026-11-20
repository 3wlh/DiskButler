import Foundation

/// 全部配置集中保存为一个 JSON：/Library/Application Support/DiskButler/DiskButler.json
/// 目录由守护/安装脚本创建并交给登录用户：App（普通用户）与 root 守护都能读写
struct DiskConfig: Codable, Equatable {
    struct Volume: Codable, Equatable {
        var label: String
        var uuid: String
        var owner: String = ""
    }

    struct Link: Codable, Equatable {
        var dir: String
        var target: String
    }

    /// 登记回挂的卷
    var volumes: [Volume] = []
    /// 内存盘大小（GB）
    var memorySizeGB: Int?
    /// 开机是否自动创建内存盘
    var memoryAutoCreate: Bool?
    /// 内存盘目录 → 链接位置
    var memoryLinks: [Link]?
    /// 以 nobrowse 挂载的卷 UUID
    var nobrowse: [String]?
    /// 登记卷阻止在访达中推出
    var protectEject: Bool?
    /// 各卷的入口位置（UUID → 路径，如 ~/DataDisk）
    var entryPaths: [String: String]?
    /// 「防止推出」放行时刻：写入后 15 秒内允许卸载，代替旧的标记文件
    var bypassSince: Double?
    /// 各卷实际已创建的入口（UUID → 路径），用于改位置时删掉旧链接
    var entryLinks: [String: String]?
    /// 待处理的「修复权限」请求（挂载点路径），守护执行后清空
    var fixRequest: String?
    /// 期望的系统级「未登录也自动挂载硬盘」设置（由守护写入 autodiskmount.plist）
    var autoMountNoLogin: Bool?
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
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(c) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        handToConsoleUser()
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

/// nobrowse 卷的入口链接：App 手动创建与守护回挂共用同一套位置与去重逻辑
enum EntryLinks {
    static func raw(uuid: String, label: String, config: DiskConfig) -> String {
        let custom = (config.entryPaths ?? [:])[uuid.uppercased()] ?? ""
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

        let oldRaw = (cfg.entryLinks ?? [:])[key] ?? ""
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
        ConfigStore.update {
            var m = $0.entryLinks ?? [:]
            m[key] = raw
            $0.entryLinks = m
        }
    }
}
