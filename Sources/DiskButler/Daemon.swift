import DiskArbitration
import Foundation
import SystemConfiguration

// notifyd 的 C 接口：系统级通知通道，不落盘、不需要提权
@_silgen_name("notify_post")
private func notify_post(_ name: UnsafePointer<CChar>) -> UInt32
@_silgen_name("notify_register_check")
private func notify_register_check(_ name: UnsafePointer<CChar>,
                                   _ outToken: UnsafeMutablePointer<Int32>) -> UInt32
@_silgen_name("notify_register_dispatch")
private func notify_register_dispatch(_ name: UnsafePointer<CChar>,
                                      _ outToken: UnsafeMutablePointer<Int32>,
                                      _ queue: DispatchQueue,
                                      _ handler: @escaping @convention(block) (Int32) -> Void) -> UInt32
@_silgen_name("notify_get_state")
private func notify_get_state(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32
@_silgen_name("notify_set_state")
private func notify_set_state(_ token: Int32, _ state: UInt64) -> UInt32

/// SCDynamicStore 的 C 回调（全局函数才能当 C 函数指针用）
private func consoleUserChangedCallback(_ store: SCDynamicStore,
                                        _ keys: CFArray,
                                        _ info: UnsafeMutableRawPointer?) {
    Daemon.handleConsoleUserChange()
}

/// 后台模式：与 App 是同一份二进制，由 launchd 以 root 身份调用，不弹任何界面
/// --daemon：常驻进程。开机即运行（登录前），挂载内存盘、回挂登记硬盘、交还权限，
///           并注册 DiskArbitration 回调阻止登记卷被推出；之后监听 /Volumes 与唤醒标记
/// --login ：登录代理，只通知守护跑一轮（此时 /dev/console 已是登录用户）
enum Daemon {
    /// App ↔ 守护的通知通道（notifyd，不落盘）
    static let notifyName = "com.local.diskbutler.tick"
    /// 通知位：跑一轮完整工作 / 关闭开机启动
    static let tickPass: UInt64 = 1
    static let tickUninstall: UInt64 = 2

    private static let workQueue = DispatchQueue(label: "com.local.diskbutler.work")
    private static let daQueue = DispatchQueue(label: "com.local.diskbutler.da")
    private static var sources: [DispatchSourceFileSystemObject] = []
    private static var daSession: DASession?
    private static var passRunning = false
    private static var passAgain = false

    /// 「防止推出」放行 15 秒：写进 JSON 配置，不再用标记文件
    static func allowUnmountFor15s() {
        ConfigStore.update { $0.bypassSince = Date().timeIntervalSince1970 }
    }

    static func run(_ args: [String]) {
        log("启动 args=\(args.dropFirst().joined(separator: " "))")
        if args.contains("--login") {
            tick(tickPass)
            log("已通知守护")
            return
        }
        migrateConfig()
        cleanLegacyFiles()
        performPass()
        installEjectBlocker()
        startWatching()
        startNotifier()
        startConsoleUserWatch()
        log("常驻等待事件")
        RunLoop.main.run()
    }

    /// 配置从 /Users/Shared 迁到 /Library/Application Support/DiskButler（root 才能写 /Library）
    private static func migrateConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: ConfigStore.dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: ConfigStore.legacyPath) {
            if !fm.fileExists(atPath: ConfigStore.path) {
                try? fm.moveItem(atPath: ConfigStore.legacyPath, toPath: ConfigStore.path)
            } else {
                try? fm.removeItem(atPath: ConfigStore.legacyPath)
            }
            log("配置已迁移到 \(ConfigStore.path)")
        }
        ConfigStore.handToConsoleUser()
    }

    /// 旧版分散配置已合并进 DiskButler.json，启动时把残留文件清掉
    private static func cleanLegacyFiles() {
        for name in ["memory-auto", "size", "memory-links", "nobrowse", "protect-eject",
                     "trigger", "request", "fix-request", "allow-unmount", "unmount-now"] {
            try? FileManager.default.removeItem(atPath: "/Users/Shared/.diskbutler-\(name)")
        }
        try? FileManager.default.removeItem(atPath: "/Users/Shared/.hide-disk-login-trigger")
    }

    /// 一轮完整工作：内存盘 / 回挂 / 交还权限 / 修复请求
    static func performPass() {
        ConfigStore.handToConsoleUser()
        applyAutoMountPreference()
        applyFixRequest()
        // 「自动创建」关着时，已挂载的内存盘卸掉
        if !MemoryDisk.autoCreate && MemoryDisk.isMounted {
            unmountMemory()
        }
        mountMemory()
        restoreVolumes()
    }

    /// 把 App 里设置的「未登录自动挂载」写进系统 plist（需 root）
    private static func applyAutoMountPreference() {
        guard let want = ConfigStore.read().autoMountNoLogin, want != AutoMount.withoutLogin else { return }
        _ = Shell.run("/usr/bin/defaults", ["write", AutoMount.domain, "AutomountDisksWithoutUserLogin",
                                            "-bool", want ? "true" : "false"])
        log("系统未登录自动挂载已设为 \(want)")
    }

    /// 卸载内存盘（root 执行）：先删掉映射链接，再 umount
    private static func unmountMemory() {
        MemoryDisk.removeLinks(home: consoleUser().map { "/Users/\($0)" })
        _ = Shell.run("/bin/bash", ["-c", """
        MP=\(shq(MemoryDisk.mountPoint))
        /sbin/mount | grep -q "tmpfs on $MP" || exit 0
        /usr/sbin/diskutil unmount "$MP" >/dev/null 2>&1 || /sbin/umount "$MP" 2>/dev/null || true
        /usr/bin/killall Finder 2>/dev/null || true
        exit 0
        """])
        log("内存盘卸载完成：\(MemoryDisk.isMounted ? "仍挂载" : "已卸载")")
    }

    /// 守护以 root 身份关掉自己：删 plist、删配置，最后 bootout
    private static func removeService() {
        log("请求：关闭开机启动（卸载服务）")
        let fm = FileManager.default
        for path in [ServiceInstaller.daemonPlist, ServiceInstaller.loginPlist, ServiceInstaller.uiPlist] {
            try? fm.removeItem(atPath: path)
        }
        let uid = consoleUser().flatMap {
            Shell.out("/usr/bin/id", ["-u", $0]).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        if !uid.isEmpty {
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(ServiceInstaller.loginLabel)"])
        }
        log("服务配置已删除，守护即将退出")
        _ = Shell.run("/bin/launchctl", ["bootout", "system/\(ServiceInstaller.daemonLabel)"])
    }

    private static func setNobrowse(uuid: String, on: Bool) {
        guard !uuid.isEmpty else { return }
        var list = VolumeScanner.persistedNobrowse()
        if on { list.insert(uuid) } else { list.remove(uuid) }
        ConfigStore.update { $0.nobrowse = list.sorted() }

        guard let info = VolumeScanner.plist(uuid),
              let dev = info["DeviceNode"] as? String, !dev.isEmpty else {
            log("nobrowse=\(on) \(uuid)：设备不在，仅记下偏好")
            return
        }
        if VolumeScanner.isMounted(info) {
            // 放行自己的卸载（防止推出会拦）
            allowUnmountFor15s()
            _ = Shell.run("/usr/sbin/diskutil", ["unmount", dev])
            Thread.sleep(forTimeInterval: 1)
            if let now = VolumeScanner.plist(uuid), VolumeScanner.isMounted(now) {
                _ = Shell.run("/usr/sbin/diskutil", ["unmount", "force", dev])
                Thread.sleep(forTimeInterval: 1)
            }
        }
        let args = on ? ["mount", "-mountOptions", "nobrowse", dev] : ["mount", dev]
        let r = Shell.run("/usr/sbin/diskutil", args)
        log("nobrowse=\(on) \(uuid) rc=\(r.code) \(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))")
    }

    /// 卷变化、唤醒标记都走这里；合并 0.5 秒内的多次事件，避免并发跑两轮
    private static var passScheduled = false
    private static func schedulePass() {
        // 一个挂载动作会产生好几个 vnode 事件，只排一次就够了，
        // 否则同一件事会被跑成好几轮（日志里会看到重复行）
        workQueue.async {
            guard !passScheduled else {
                passAgain = true
                return
            }
            passScheduled = true
            workQueue.asyncAfter(deadline: .now() + 0.5) {
                passScheduled = false
                if passRunning {
                    passAgain = true
                    return
                }
                passRunning = true
                performPass()
                passRunning = false
                if passAgain {
                    passAgain = false
                    schedulePass()
                }
            }
        }
    }

    // MARK: - 事件监听（launchd 不再用 WatchPaths，改为进程内自监听）

    private static func startWatching() {
        watchDirectory("/Volumes")
    }

    private static func watchDirectory(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: workQueue
        )
        src.setEventHandler { schedulePass() }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources.append(src)
    }

    // MARK: - 登录事件（登录前跑设备侧，登录后补用户侧）

    private static var consoleStore: SCDynamicStore?

    /// 登录窗口会维护 State:/Users/ConsoleUser，登录/切换用户/注销时它都会变。
    /// 监听它就不需要登录代理：守护登录前挂载，登录后再补建入口、交还属主、应用内存盘链接。
    private static func startConsoleUserWatch() {
        guard let store = SCDynamicStoreCreate(nil, "com.local.diskbutler" as CFString,
                                               consoleUserChangedCallback, nil) else { return }
        SCDynamicStoreSetNotificationKeys(store, ["State:/Users/ConsoleUser"] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, workQueue)
        consoleStore = store
    }

    static func handleConsoleUserChange() {
        log("登录用户变化，跑一轮")
        schedulePass()
    }

    /// 新设备出现（开机时 USB 常晚于守护启动）：立刻跑一轮，把登记卷挂上，
    /// 不再依赖 /Volumes 变化或用户手动打开 App
    static func handleDiskAppeared() {
        log("设备出现，跑一轮")
        schedulePass()
    }

    // MARK: - 通知通道（notifyd，不落盘）

    private static var notifyToken: Int32 = 0

    private static func startNotifier() {
        notify_register_dispatch(notifyName, &notifyToken, workQueue) { _ in
            var state: UInt64 = 0
            notify_get_state(notifyToken, &state)
            guard state != 0 else { return }
            notify_set_state(notifyToken, 0)
            if state & tickPass != 0 { schedulePass() }
            if state & tickUninstall != 0 { removeService() }
        }
    }

    /// App 侧：置位并通知守护（同名通知是系统级的，不需要文件与权限）
    static func tick(_ bits: UInt64) {
        var token: Int32 = 0
        guard notify_register_check(notifyName, &token) == 0 else { return }
        var state: UInt64 = 0
        notify_get_state(token, &state)
        notify_set_state(token, state | bits)
        notify_post(notifyName)
    }

    /// 请守护对指定卷交还属主
    static func requestFix(_ mountPoint: String) {
        ConfigStore.update { $0.fixRequest = mountPoint }
        tick(tickPass)
    }

    // MARK: - 防止推出（DiskArbitration dissenter）

    private static func installEjectBlocker() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            log("防止推出：DA 会话创建失败")
            return
        }
        DASessionSetDispatchQueue(session, daQueue)
        DARegisterDiskUnmountApprovalCallback(session, nil, daApproval, nil)
        DARegisterDiskEjectApprovalCallback(session, nil, daApproval, nil)
        DARegisterDiskAppearedCallback(session, nil, daDiskAppeared, nil)
        daSession = session
        log("防止推出：已注册")
    }

    static func approve(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard protectionEnabled(), !bypassActive() else { return nil }
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        var matched = false
        if let raw = desc[kDADiskDescriptionVolumeUUIDKey as String] {
            let uuid = (CFUUIDCreateString(kCFAllocatorDefault, raw as! CFUUID) as String).uppercased()
            matched = registeredUUIDs().contains(uuid)
        } else if let media = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String {
            // 整盘推出时 DA 给的是 media（没有卷 UUID）：看有没有登记卷挂在它上面
            matched = registeredDevice(onMedia: media)
        }
        guard matched else { return nil }
        log("阻止推出 \(desc[kDADiskDescriptionMediaNameKey as String] as? String ?? "?")")
        let dissenter = DADissenterCreate(kCFAllocatorDefault,
                                          DAReturn(kDAReturnBusy),
                                          "该磁盘已设为常驻，DiskButler 已阻止推出（可在 App 里关闭）" as CFString)
        return Unmanaged.passRetained(dissenter)
    }

    /// 是否有登记卷位于该物理盘上（设备名形如 disk7s1，父设备 disk7）
    private static func registeredDevice(onMedia media: String) -> Bool {
        for uuid in registeredUUIDs() {
            guard let info = VolumeScanner.plist(uuid),
                  let dev = info["DeviceNode"] as? String else { continue }
            if dev.hasPrefix("/dev/\(media)s") { return true }
        }
        return false
    }

    private static func protectionEnabled() -> Bool {
        ConfigStore.read().protectEject ?? true
    }

    /// 放行窗口：bypassSince 写入后 15 秒内有效
    private static func bypassActive() -> Bool {
        guard let t = ConfigStore.read().bypassSince else { return false }
        return Date().timeIntervalSince1970 - t < 15
    }

    private static func registeredUUIDs() -> Set<String> {
        Set(ConfStore.load().map { $0.uuid.uppercased() })
    }

    /// 请求守护对指定卷交还属主（写在配置里，随通知一起交给守护）
    private static func applyFixRequest() {
        let path = (ConfigStore.read().fixRequest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/Volumes/") else { return }
        ConfigStore.update { $0.fixRequest = nil }
        log("修复权限请求：\(path)")
        handOver(path, fallbackOwner: "")
    }

    /// 不输出守护日志（Release 与 Debug 均不落盘）
    private static func log(_: String) {}

    // MARK: - 内存盘

    private static func mountMemory(force: Bool = false) {
        // 叠挂会产生多个同名「Memory」卷，发现就清掉多余的
        if MemoryDisk.hasDuplicates {
            log("内存盘：发现重复挂载，清理")
            _ = Shell.run("/bin/bash", ["-c", MemoryDisk.dedupeScript])
        }
        if !force {
            // 事件驱动：盘不存在就建（autoCreate 开着时），存在就不动
            guard MemoryDisk.autoCreate else {
                if MemoryDisk.isMounted { log("内存盘：已关闭「自动创建」，不动") }
                return
            }
            // App 刚点过「卸载」：15 秒内不重建，避免"卸了又立刻回来"
            if bypassActive() {
                log("内存盘：刚由 App 卸载，本次跳过创建")
                return
            }
        }
        guard !MemoryDisk.isMounted else {
            if let user = consoleUser() { MemoryDisk.applyLinks(home: "/Users/\(user)") }
            return
        }
        for _ in 0..<3 {
            _ = Shell.run("/bin/bash", ["-c", MemoryDisk.rootMountScript()])
            if MemoryDisk.isMounted { break }
            Thread.sleep(forTimeInterval: 2)
        }
        log("内存盘 \(MemoryDisk.isMounted ? "已挂载" : "挂载失败")")
        guard MemoryDisk.isMounted, let user = consoleUser() else { return }
        // 开机早期 /dev/console 是 root，拿不到用户就不建链接，等登录标记再触发
        MemoryDisk.applyLinks(home: "/Users/\(user)")
    }

    // MARK: - 回挂 + 交还权限

    private static func restoreVolumes() {
        var pending = ConfStore.load()
        log("登记卷 \(pending.count) 个")
        guard !pending.isEmpty else { return }
        for _ in 0..<3 {
            pending = pending.filter { entry in
                // 设备查不到（拔出）：等重插，/Volumes 变化会再次唤醒
                guard var info = VolumeScanner.plist(entry.uuid) else {
                    log("\(entry.label): diskutil 查不到设备，跳过")
                    return false
                }
                let wantNobrowse = VolumeScanner.persistedNobrowse().contains(entry.uuid.uppercased())
                if !VolumeScanner.isMounted(info),
                   let dev = info["DeviceNode"] as? String, !dev.isEmpty {
                    let cmd = wantNobrowse ? ["mount", "-mountOptions", "nobrowse", dev] : ["mount", dev]
                    let r = Shell.run("/usr/sbin/diskutil", cmd)
                    log("\(entry.label): 未挂载，执行 diskutil \(cmd.joined(separator: " ")) rc=\(r.code) out=\(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
                    // 挂载后必须重新读 plist，否则拿到的是挂载前的信息（没有 MountPoint）
                    if let fresh = VolumeScanner.plist(entry.uuid) { info = fresh }
                }
                guard let mp = VolumeScanner.mountPoint(info) else {
                    log("\(entry.label): 挂载后仍无挂载点")
                    return true
                }
                // 系统自动挂载的卷不带 nobrowse：按偏好重挂一次
                if wantNobrowse && !VolumeScanner.isNobrowse(mp) {
                    setNobrowse(uuid: entry.uuid.uppercased(), on: true)
                }
                // 访达里隐藏时，在入口位置留一个符号链接（默认 ~/卷名，自定义位置与 App 共用同一套逻辑）
                if wantNobrowse, let user = consoleUser() {
                    EntryLinks.ensure(uuid: entry.uuid.uppercased(), label: entry.label,
                                      mountPoint: mp, home: "/Users/\(user)")
                }
                handOver(mp, fallbackOwner: entry.owner)
                return false
            }
            if pending.isEmpty { return }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// 卷根 + 首层 root 属主目录交还当前登录用户（取不到时退回登记时记下的 UID:GID）
    private static func handOver(_ mp: String, fallbackOwner: String) {
        guard mp.hasPrefix("/Volumes/") else { return }
        guard let owner = consoleOwner() ?? validOwner(fallbackOwner) else { return }
        if statOwner(mp) != owner {
            let r = Shell.run("/usr/sbin/chown", [owner, mp])
            if r.code != 0 {
                log("\(mp): chown 被系统拒绝，需要给 DiskButler 完全磁盘访问权限")
            }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mp) else { return }
        for name in names {
            let path = mp + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard statUID(path) == "0" else { continue }
            _ = Shell.run("/usr/sbin/chown", [owner, path])
        }
    }

    // MARK: - 小工具

    private static func statOwner(_ path: String) -> String {
        Shell.out("/usr/bin/stat", ["-f", "%u:%g", path]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func statUID(_ path: String) -> String {
        Shell.out("/usr/bin/stat", ["-f", "%u", path]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func consoleOwner() -> String? {
        let uid = statUID("/dev/console")
        guard uid != "0" else { return nil }
        let gid = Shell.out("/usr/bin/stat", ["-f", "%g", "/dev/console"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(uid):\(gid)"
    }

    private static func consoleUser() -> String? {
        let name = Shell.out("/usr/bin/stat", ["-f", "%Su", "/dev/console"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "root" || name == "loginwindow" ? nil : name
    }

    private static func validOwner(_ raw: String) -> String? {
        let owner = raw.filter { $0.isNumber || $0 == ":" }
        let parts = owner.split(separator: ":")
        guard parts.count == 2, let uid = Int(parts[0]), uid != 0 else { return nil }
        return owner
    }
}

/// DiskArbitration 回调必须是 C 函数指针，不能捕获上下文，因此放在文件作用域
private func daApproval(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) -> Unmanaged<DADissenter>? {
    Daemon.approve(disk)
}

private func daDiskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    Daemon.handleDiskAppeared()
}
