import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var volumes: [Volume] = []
    @Published var serviceInstalled = false
    @Published var serviceNeedsUpgrade = false
    @Published var registeredCount = 0
    @Published var memoryMounted = false
    @Published var memorySizeGB = MemoryDisk.sizeGB
    @Published var memoryAuto = MemoryDisk.autoCreate
    @Published var memoryLinks = MemoryDisk.links()
    @Published var message: String?
    @Published var messageIsError = false
    @Published var busy = false
    /// 防止推出（登记卷被 Finder 推出时由守护拦下）
    @Published var protectEject = true
    /// 系统级：无用户登录时也自动挂载硬盘（autodiskmount.plist）
    @Published var autoMountNoLogin = false
    /// 各卷入口位置（UUID → 路径，留空表示默认 ~/卷名）
    @Published var entryPaths: [String: String] = [:]

    private let watchQueue = DispatchQueue(label: "com.local.diskbutler.ui-watch")
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingRefresh: Task<Void, Never>?

    init() {
        refresh()
        // 登录后 App 一启动就让守护跑一轮（此时才有登录用户，能补建入口/交还属主）
        Daemon.tick(Daemon.tickPass)
        // 事件驱动：/Volumes 变化（插入、拔出、挂载、卸载、内存盘创建）+ 系统挂载通知
        watchVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            }
        }
    }

    /// /Volumes 目录的写入事件 = 有卷被挂载/卸载；比轮询快且不空转
    private func watchVolumes() {
        let fd = open("/Volumes", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: watchQueue
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers.append(src)
    }

    /// 合并短时间内的多次事件（挂载往往连着好几个写入事件）
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private var scanning = false
    private var needsRescan = false

    /// 扫描放到后台线程：diskutil 每次要几十上百毫秒，放主线程会卡 UI
    func refresh() {
        // 扫描/提权进行中先记一笔，结束后补扫，避免状态停在旧值
        if scanning || busy {
            needsRescan = true
            return
        }
        scanning = true
        needsRescan = false
        let conf = ConfStore.load()
        Task.detached(priority: .utility) {
            let vols = VolumeScanner.scan(conf: conf)
            let installed = ServiceInstaller.installed
            let upgrade = ServiceInstaller.needsUpgrade
            let mounted = MemoryDisk.isMounted
            let sizeGB = MemoryDisk.sizeGB
            let auto = MemoryDisk.autoCreate
            let links = MemoryDisk.links()
            let protect = ConfigStore.read().protectEject ?? true
            let autoMount = AutoMount.withoutLogin
            let entries = ConfigStore.read().entryPaths ?? [:]
            await MainActor.run {
                self.volumes = vols
                self.registeredCount = conf.count
                self.serviceInstalled = installed
                self.serviceNeedsUpgrade = upgrade
                self.memoryMounted = mounted
                self.memorySizeGB = sizeGB
                self.memoryAuto = auto
                self.memoryLinks = links
                self.protectEject = protect
                self.autoMountNoLogin = autoMount
                self.entryPaths = entries
                self.scanning = false
                if self.needsRescan {
                    self.needsRescan = false
                    self.refresh()
                }
            }
        }
    }

    func setProtectEject(_ on: Bool) {
        ConfigStore.update { $0.protectEject = on }
        protectEject = on
        notify(on ? "已开启防止推出（登记的磁盘无法被推出）" : "已关闭防止推出")
    }

    /// 系统级开关：登录窗口（无用户登录）是否自动挂载硬盘
    func setAutoMountNoLogin(_ on: Bool) {
        if ServiceInstaller.installed {
            // 交给 root 守护写系统 plist，App 不提权
            ConfigStore.update { $0.autoMountNoLogin = on }
            Daemon.tick(Daemon.tickPass)
            autoMountNoLogin = on
            notify(on ? "已允许未登录时自动挂载硬盘" : "已禁止未登录时自动挂载硬盘（登录后再挂）")
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refresh()
            }
        } else {
            runPrivileged(on ? "已允许未登录时自动挂载硬盘" : "已禁止未登录时自动挂载硬盘") {
                try ServiceInstaller.setAutoMount(on)
                return nil
            }
        }
    }

    // MARK: - 卷操作（用户态）

    func toggleHidden(_ v: Volume) {
        let flag = v.hidden ? "nohidden" : "hidden"
        let r = Shell.run("/usr/bin/chflags", [flag, v.mountPoint])
        if r.ok {
            // Finder 只在挂载/自身启动时评估卷图标；重启放后台，避免界面卡住
            Task.detached(priority: .utility) { Shell.run("/usr/bin/killall", ["Finder"]) }
            notify(v.hidden ? "「\(v.name)」桌面图标已恢复" : "「\(v.name)」桌面图标已隐藏")
        } else {
            fail("修改失败：请先对该卷执行「修复权限」\n\(r.err)")
        }
        refresh()
    }

    func mount(_ v: Volume) {
        var dev = v.deviceNode
        if dev.isEmpty, let info = VolumeScanner.plist(v.uuid) {
            dev = (info["DeviceNode"] as? String) ?? ""
        }
        guard !dev.isEmpty else {
            fail("找不到设备节点（盘可能已拔出）")
            return
        }
        let name = v.name
        busy = true
        Task.detached(priority: .userInitiated) {
            let r = Shell.run("/usr/sbin/diskutil", ["mount", dev])
            await MainActor.run {
                self.busy = false
                if r.ok { self.notify("「\(name)」已挂载") } else { self.fail("挂载失败：\(r.err)") }
                self.refresh()
            }
        }
    }

    /// 以 nobrowse 重挂（不显示在桌面和访达侧边栏）；普通用户权限即可完成
    func toggleNobrowse(_ v: Volume) {
        let on = !v.nobrowse
        // 记下偏好：守护开机/回挂时照此挂载
        var list = VolumeScanner.persistedNobrowse()
        if on { list.insert(v.uuid.uppercased()) } else { list.remove(v.uuid.uppercased()) }
        ConfigStore.update { $0.nobrowse = list.sorted() }

        guard !v.deviceNode.isEmpty, v.mounted else {
            notify(on ? "已记下设置，挂载后生效" : "已取消")
            refresh()
            return
        }
        Daemon.allowUnmountFor15s()
        let dev = v.deviceNode
        let mp = v.mountPoint
        let name = v.name
        let entryRaw = (ConfigStore.read().entryPaths ?? [:])[v.uuid.uppercased()] ?? ""
        let entryUUID = v.uuid.uppercased()
        busy = true
        Task.detached(priority: .userInitiated) {
            var r = Shell.run("/usr/sbin/diskutil", ["unmount", dev])
            if !r.ok {
                r = Shell.run("/usr/sbin/diskutil", ["unmount", "force", dev])
            }
            let args = on ? ["mount", "-mountOptions", "nobrowse", dev] : ["mount", dev]
            let m = Shell.run("/usr/sbin/diskutil", args)
            let ok = m.ok && VolumeScanner.isNobrowse(mp) == on
            var msg: String?
            if ok {
                // 访达里看不到时，默认在用户目录留一个同名的入口（符号链接）
                let fm = FileManager.default
                // 入口位置：用编辑框里的值，留空就是 ~/卷名
                let raw = entryRaw.isEmpty ? "~/\(name)" : entryRaw
                let entry = (raw as NSString).expandingTildeInPath
                if on {
                    // 位置改过：先删掉上次创建的入口链接，避免重复创建
                    let key = mp.isEmpty ? "" : entryUUID
                    let oldRaw = (ConfigStore.read().entryLinks ?? [:])[key] ?? ""
                    if !oldRaw.isEmpty, oldRaw != raw {
                        let oldPath = (oldRaw as NSString).expandingTildeInPath
                        if let d = try? fm.destinationOfSymbolicLink(atPath: oldPath), d == mp {
                            try? fm.removeItem(atPath: oldPath)
                        }
                    }
                    if !fm.fileExists(atPath: entry),
                       (try? fm.destinationOfSymbolicLink(atPath: entry)) == nil {
                        try? fm.createSymbolicLink(atPath: entry, withDestinationPath: mp)
                    }
                    ConfigStore.update { $0.entryLinks = Self.upsert(c: $0.entryLinks, key: key, value: raw) }
                    msg = "「\(name)」已从桌面和访达侧边栏隐藏；入口：\(raw)"
                } else {
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: entry), dest == mp {
                        try? fm.removeItem(atPath: entry)
                    }
                    ConfigStore.update { $0.entryLinks = Self.upsert(c: $0.entryLinks, key: entryUUID, value: "") }
                    msg = "「\(name)」已恢复在访达中显示"
                }
            }
            await MainActor.run {
                self.busy = false
                if let msg { self.notify(msg) }
                else { self.fail("重挂失败：\(m.err.isEmpty ? m.out : m.err)") }
                self.refresh()
            }
        }
    }

    // MARK: - 登记（提权）

    func register(_ v: Volume) {
        var entries = ConfStore.load()
        entries.removeAll { $0.uuid == v.uuid }
        entries.append(ConfEntry(label: v.name, uuid: v.uuid,
                                 owner: "\(getuid()):\(getgid())"))
        do {
            try ConfStore.save(entries: entries)
            notify(ServiceInstaller.installed
                   ? "已登记「\(v.name)」"
                   : "登记成功；回挂服务尚未安装，登记暂不生效")
        } catch {
            fail(error.localizedDescription)
        }
        refresh()
    }

    func unregister(_ v: Volume) {
        var entries = ConfStore.load()
        entries.removeAll { $0.uuid == v.uuid }
        do {
            try ConfStore.save(entries: entries)
            notify("已从回挂配置移除「\(v.name)」")
        } catch {
            fail(error.localizedDescription)
        }
        refresh()
    }

    func fixOwner(_ v: Volume) {
        runPrivileged("「\(v.name)」权限已交还当前用户") {
            try ServiceInstaller.fixOwner(mountPoint: v.mountPoint)
        }
    }

    // MARK: - 后台服务（二进制守护：开机挂内存盘 + 回挂硬盘）

    /// 在指定位置建一个指向卷挂载点的符号链接（访达隐藏后仍可进入）
    func createEntry(_ v: Volume, at rawPath: String) {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // 留空就在用户目录建与卷同名的入口
        let raw = trimmed.isEmpty ? "~/\(v.name)" : trimmed
        let path = (raw as NSString).expandingTildeInPath
        guard !path.isEmpty, path != "/" else {
            fail("请输入有效位置")
            return
        }
        let fm = FileManager.default
        let key = v.uuid.uppercased()
        let cfg = ConfigStore.read()
        // 位置改过：先把这条卷上次创建的入口链接删掉，避免重复创建
        let oldRaw = (cfg.entryLinks ?? [:])[key] ?? (cfg.entryPaths ?? [:])[key] ?? ""
        if !oldRaw.isEmpty, !v.mountPoint.isEmpty {
            let oldPath = (oldRaw as NSString).expandingTildeInPath
            if oldPath != path,
               let dest = try? fm.destinationOfSymbolicLink(atPath: oldPath),
               dest == v.mountPoint {
                try? fm.removeItem(atPath: oldPath)
            }
        }
        if fm.fileExists(atPath: path) {
            fail("该位置已存在：\(path)")
            return
        }
        do {
            try fm.createSymbolicLink(atPath: path, withDestinationPath: v.mountPoint)
            setEntryPath(raw, for: v)
            ConfigStore.update { $0.entryLinks = Self.upsert(c: $0.entryLinks, key: key, value: raw) }
            notify("已创建入口：\(path)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// 写入/删除字典项（空值表示删除）
    nonisolated private static func upsert(c: [String: String]?, key: String, value: String) -> [String: String] {
        var m = c ?? [:]
        if value.isEmpty { m.removeValue(forKey: key) } else { m[key] = value }
        return m
    }

    /// 记录某卷的入口位置（留空表示默认 ~/卷名）
    func setEntryPath(_ text: String, for v: Volume) {
        let key = v.uuid.uppercased()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        entryPaths[key] = t
        ConfigStore.update { c in
            var m = c.entryPaths ?? [:]
            if t.isEmpty { m.removeValue(forKey: key) } else { m[key] = t }
            c.entryPaths = m
        }
    }

    func installService() {
        runPrivileged("开机启动已开启（后台守护已运行）") {
            try ServiceInstaller.install()
            return nil
        }
    }

    func uninstallService() {
        guard serviceInstalled else {
            notify("开机启动已关闭")
            refresh()
            return
        }
        // 交给 root 守护自己收尾（删 plist + bootout），App 不必再弹密码
        Daemon.tick(Daemon.tickUninstall)
        notify("正在关闭后台服务…")
        Task { @MainActor in
            // 等守护处理完（最多约 3 秒），再核实 plist 是否已删除
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !ServiceInstaller.installed { break }
            }
            self.refresh()
            if ServiceInstaller.installed {
                self.fail("后台服务没有响应：请重启电脑后再试")
            } else {
                self.notify("开机启动已关闭（登记与设置已保留）")
            }
        }
    }

    // MARK: - 内存盘

    func memoryMount() {
        if serviceInstalled {
            Daemon.tick(Daemon.tickPass)
            notify("已交由后台服务创建内存盘（\(memorySizeGB)G）")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.refresh()
            }
            return
        }
        runPrivileged("内存盘已挂载（\(memorySizeGB)G，重启清空）") {
            try MemoryDisk.mount()
        }
    }

    func memoryUnmount() {
        guard !MemoryDisk.autoCreate else {
            fail("「自动创建」开着时卸载会被立刻重建，请先关闭它再卸载")
            return
        }
        // 让守护在 15 秒内别重建
        if serviceInstalled {
            Daemon.tick(Daemon.tickPass)
            notify("已交由后台服务卸载内存盘")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.refresh()
            }
            return
        }
        runPrivileged("内存盘已卸载，内容已清空") {
            try MemoryDisk.unmount()
            return nil
        }
    }

    /// 大小只在卸载后改（挂载中的改动不会生效，避免误解）
    func setMemorySize(_ gb: Int) {
        MemoryDisk.setSizeGB(gb)
        memorySizeGB = MemoryDisk.sizeGB
    }

    func setMemoryAuto(_ on: Bool) {
        MemoryDisk.setAutoCreate(on)
        // 配置可能被 root 占用而写不进去，别让开关假装成功
        let actual = MemoryDisk.autoCreate
        memoryAuto = actual
        if actual != on {
            fail("设置没有保存：配置文件被 root 占用。重启「开机启动」让守护交还属主后再试")
            return
        }
        // 打开「自动创建」时，盘不存在就立刻建；关掉时，已挂载的就卸载
        if on && !MemoryDisk.isMounted {
            memoryMount()
        } else if !on && MemoryDisk.isMounted {
            memoryUnmount()
        }
    }

    /// 添加「内存盘目录 → 链接位置」映射；已挂载时立即建链接
    func addMemoryLink(dir: String, target: String) {
        let d = dir.trimmingCharacters(in: .whitespaces)
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, !t.isEmpty else { return }
        var list = MemoryDisk.links()
        guard !list.contains(where: { $0.dir == d || $0.target == t }) else {
            fail("目录或链接位置已存在")
            return
        }
        list.append(MemoryDisk.Link(dir: d, target: t))
        MemoryDisk.saveLinks(list)
        memoryLinks = list
        if MemoryDisk.isMounted { MemoryDisk.applyLinks() }
    }

    func removeMemoryLink(_ link: MemoryDisk.Link) {
        // 必须先按旧配置删链接，再保存新配置（否则读到的列表里已经没有这一条）
        MemoryDisk.removeLinks(home: NSHomeDirectory())
        var list = MemoryDisk.links()
        list.removeAll { $0 == link }
        MemoryDisk.saveLinks(list)
        memoryLinks = list
        if MemoryDisk.isMounted { MemoryDisk.applyLinks() }
    }

    // MARK: - 结果提示

    /// 统一执行提权动作：忙碌态 → 结果提示 → 刷新
    private func runPrivileged(_ successText: String, _ body: () throws -> String?) {
        busy = true
        defer { busy = false; refresh() }
        do {
            if let warning = try body() {
                message = warning
                messageIsError = false
            } else {
                notify(successText)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func notify(_ text: String) {
        message = text
        messageIsError = false
    }

    func fail(_ text: String) {
        message = text
        messageIsError = true
    }

    func clearMessage() {
        message = nil
    }
}
