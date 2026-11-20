import Foundation

/// 内存盘（tmpfs）状态与操作
enum MemoryDisk {
    static let mountPoint = "/Volumes/Memory"

    /// 内存盘内的目录，以及要创建的符号链接位置（target 支持 ~）
    struct Link: Identifiable, Hashable {
        var dir: String
        var target: String
        var id: String { dir + "|" + target }
    }

    static var autoCreate: Bool { ConfigStore.read().memoryAutoCreate ?? true }

    static func setAutoCreate(_ on: Bool) {
        ConfigStore.update { $0.memoryAutoCreate = on }
    }

    static func links() -> [Link] {
        let list = ConfigStore.read().memoryLinks
            ?? [DiskConfig.Link(dir: "Downloads", target: "~/Downloads/DownloadsRAM")]
        return list.map { Link(dir: $0.dir, target: $0.target) }
    }

    static func saveLinks(_ list: [Link]) {
        ConfigStore.update {
            $0.memoryLinks = list.map { DiskConfig.Link(dir: $0.dir, target: $0.target) }
        }
    }

    // MARK: - 大小配置

    /// 物理内存（GB，取整）
    static var physicalGB: Int { max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)) }

    /// 默认大小：物理内存的 1/4
    static var defaultSizeGB: Int { max(1, physicalGB / 4) }

    /// 当前设置的大小（GB）
    static var sizeGB: Int {
        let v = ConfigStore.read().memorySizeGB ?? defaultSizeGB
        return min(max(1, v), physicalGB)
    }

    static var sizeString: String { "\(sizeGB)G" }

    static func setSizeGB(_ gb: Int) {
        let v = min(max(1, gb), physicalGB)
        ConfigStore.update { $0.memorySizeGB = v }
    }

    // MARK: - 状态

    /// 当前所有 tmpfs 挂载点（同一路径出现两次 = 被叠挂了两层）
    static var tmpfsMounts: [String] {
        Shell.out("/sbin/mount", []).split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("tmpfs on "), let r = line.range(of: " (") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 9)..<r.lowerBound])
        }
    }

    static var isMounted: Bool { tmpfsMounts.contains(mountPoint) }

    /// 是否有重复挂载（同一挂载点叠了多层，或存在 Memory 1/2… 之类的多余挂载点）
    static var hasDuplicates: Bool {
        tmpfsMounts.filter { $0 == mountPoint }.count > 1
            || tmpfsMounts.contains { $0 != mountPoint && $0.hasPrefix(mountPoint + " ") }
    }

    // MARK: - 挂载 / 卸载

    /// 挂载（需 root；目录里的链接由 App 用户态创建）
    static func mount() throws -> String? {
        _ = try PrivilegedRunner.run(rootMountScript())
        applyLinks()
        guard isMounted else {
            throw ButlerError.message("内存盘创建失败：系统拒绝了 tmpfs 挂载")
        }
        return nil
    }

    /// 清理重复挂载：只保留最底层一个；需要 root
    static let dedupeScript = """
    MP=\(shq(mountPoint))
    # 其它 Memory* 挂载点（路径可能含空格，按整行截取路径再比较）
    /sbin/mount | sed -n 's/^tmpfs on \\(.*\\) (.*$/\\1/p' | while IFS= read -r P; do
      [ "$P" = "$MP" ] && continue
      case "$P" in
        "$MP "*) /usr/sbin/diskutil unmount "$P" >/dev/null 2>&1 || /sbin/umount "$P" 2>/dev/null || true ;;
      esac
    done
    # 同一挂载点叠挂多层：逐层卸掉，直到只剩一层
    CNT=$(/sbin/mount | grep -cF "tmpfs on $MP (" || true)
    while [ "${CNT:-0}" -gt 1 ]; do
      /sbin/umount "$MP" 2>/dev/null || break
      NCNT=$(/sbin/mount | grep -cF "tmpfs on $MP (" || true)
      [ "${NCNT:-0}" -lt "${CNT:-0}" ] || break
      CNT=$NCNT
    done
    """

    /// root 侧挂载脚本：App 提权执行与开机守护（--daemon）共用同一份逻辑
    static func rootMountScript() -> String {
        let uid = getuid(), gid = getgid()
        var dirs = ""
        for link in links() where !link.dir.isEmpty {
            let path = mountPoint + "/" + link.dir
            dirs += """
            mkdir -p \(shq(path))
            chown \(uid):\(gid) \(shq(path))
            chmod 777 \(shq(path))

            """
        }
        return """
        set -e
        MP=\(shq(mountPoint))
        mkdir -p "$MP"

        # 串行化：App 与守护、或连续多次点「挂载」可能同时执行，
        # 叠挂会让访达桌面出现多个同名的 Memory 卷
        LOCK=/tmp/.diskbutler-memory.lock
        n=0
        while ! mkdir "$LOCK" 2>/dev/null; do
          n=$((n + 1))
          if [ "$n" -ge 50 ]; then rmdir "$LOCK" 2>/dev/null || true; break; fi
          sleep 0.2
        done
        trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

        \(dedupeScript)

        CNT=$(/sbin/mount | grep -cF "tmpfs on $MP (" || true)
        if [ "${CNT:-0}" -eq 0 ]; then
          /sbin/mount_tmpfs -s \(sizeString) "$MP"
          chmod 1777 "$MP"
          chflags hidden "$MP" 2>/dev/null || true
        fi
        \(dirs)
        """
    }

    /// 卸载（内容立即丢失，UI 侧必须二次确认）
    static func unmount() throws {
        removeLinks()
        _ = try PrivilegedRunner.run(
            """
            MP=\(shq(mountPoint))
            /sbin/mount | grep -q "tmpfs on $MP" || exit 0
            # 优先走 diskutil：会通知 DiskArbitration，访达桌面图标才会消失
            /usr/sbin/diskutil unmount "$MP" >/dev/null 2>&1 || /sbin/umount "$MP" 2>/dev/null || true
            if /sbin/mount | grep -q "tmpfs on $MP"; then
                echo "内存盘仍在使用中，卸载失败（请关闭正在使用 /Volumes/Memory 的程序后重试）" >&2
                exit 1
            fi
            # 强制卸载时访达可能留下"幽灵"桌面图标，重启访达清掉
            /usr/bin/killall Finder 2>/dev/null || true
            exit 0
            """
        )
    }

    // MARK: - 目录 → 链接

    /// 按配置在用户态创建符号链接（已存在的真实文件/目录不动）
    /// - Parameter home: 守护以 root 运行时用它展开 ~（root 的 ~ 是 /var/root）
    static func applyLinks(home: String? = nil) {
        let fm = FileManager.default
        for link in links() {
            let target: String
            if link.target.hasPrefix("~") {
                target = (home ?? NSHomeDirectory()) + String(link.target.dropFirst())
            } else {
                target = link.target
            }
            let dir = mountPoint + "/" + link.dir
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let attrs = try? fm.attributesOfItem(atPath: target) {
                guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
                try? fm.removeItem(atPath: target)
            }
            try? fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: target, withDestinationPath: dir)
        }
    }

    /// 只删除指向内存盘的那些链接
    static func removeLinks(home: String? = nil) {
        let fm = FileManager.default
        for link in links() {
            let target = link.target.hasPrefix("~")
                ? (home ?? NSHomeDirectory()) + String(link.target.dropFirst())
                : link.target
            guard let attrs = try? fm.attributesOfItem(atPath: target),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                  (try? fm.destinationOfSymbolicLink(atPath: target))?.hasPrefix(mountPoint) == true else { continue }
            try? fm.removeItem(atPath: target)
        }
    }
}
