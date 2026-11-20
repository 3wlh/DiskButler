import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    @State private var confirmUninstallService = false
    @State private var newLinkDir = ""
    @State private var newLinkTarget = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let msg = state.message {
                banner(msg)
            }
            Divider()
            volumesSection
            Divider()
            memorySection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 390)
        .alert("卸载守护程序？", isPresented: $confirmUninstallService) {
            Button("取消", role: .cancel) {}
            Button("卸载", role: .destructive) { state.uninstallService() }
        } message: {
            Text("将停止后台服务（不再开机挂载、回挂）；已有的登记、隐藏设置会保留，重新开启后继续生效。")
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: state.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(state.messageIsError ? .red : .green)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                state.clearMessage()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 外置磁盘

    private var volumesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("外置磁盘").font(.caption).foregroundStyle(.secondary)
            if state.volumes.isEmpty {
                Text("未检测到外置磁盘").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(state.volumes) { volume in
                    VolumeRow(volume: volume, state: state)
                    if volume.id != state.volumes.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: - 内存盘

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("内存盘 Memory（\(state.memorySizeGB)G）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(state.memoryMounted ? "已挂载" : "未挂载")
                    .font(.caption)
                    .foregroundStyle(state.memoryMounted ? .green : .secondary)
            }
            HStack(spacing: 6) {
                Stepper(value: Binding(
                    get: { state.memorySizeGB },
                    set: { state.setMemorySize($0) }
                ), in: 1...MemoryDisk.physicalGB) {
                    Text("大小 \(state.memorySizeGB) GB")
                }
                .font(.caption)
                .disabled(state.memoryMounted)
                Spacer()
                Text(state.memoryMounted ? "卸载后可改大小" : "默认 1/4 内存")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Toggle("自动创建", isOn: Binding(
                get: { state.memoryAuto },
                set: { state.setMemoryAuto($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("开启：内存盘不存在就自动创建；关闭：自动卸载内存盘")

            ForEach(state.memoryLinks) { link in
                HStack(spacing: 4) {
                    Text("\(link.dir) → \(link.target)")
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        state.removeMemoryLink(link)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("删除这条映射")
                }
            }
            HStack(spacing: 4) {
                TextField("目录", text: $newLinkDir)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 86)
                    .font(.caption2)
                TextField("链接位置（~/…）", text: $newLinkTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                Button("添加") {
                    state.addMemoryLink(dir: newLinkDir, target: newLinkTarget)
                    newLinkDir = ""
                    newLinkTarget = ""
                }
                .font(.caption)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.serviceNeedsUpgrade {
                HStack(spacing: 6) {
                    Label("后台服务是旧版本，需要升级", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("升级") { state.installService() }
                        .font(.caption)
                }
            }
            if state.serviceInstalled && state.registeredCount == 0 {
                Label("服务已开但未登记磁盘，回挂不会生效", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Toggle("安装守护程序", isOn: Binding(
                    get: { state.serviceInstalled },
                    set: { on in
                        if on {
                            state.installService()
                        } else {
                            confirmUninstallService = true
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("开启后：开机（登录前）自动挂载内存盘（\(state.memorySizeGB)G）、回挂登记的硬盘并交还权限")
                Toggle("防止推出", isOn: Binding(
                    get: { state.protectEject },
                    set: { state.setProtectEject($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("开启后：已登记的磁盘在访达里推出会失败（提示正在使用），需在 App 内卸载")
                Toggle("未登录挂载硬盘", isOn: Binding(
                    get: { state.autoMountNoLogin },
                    set: { state.setAutoMountNoLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("系统级设置：开启后，即使停在登录窗口（无用户登录），外置硬盘也会自动挂载；关闭则等用户登录后才挂载")
            }
        }
    }
}

/// 单个卷的行：状态、隐藏开关、更多操作
private struct VolumeRow: View {
    let volume: Volume
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: volume.mounted ? "externaldrive.fill" : "externaldrive")
                    .foregroundStyle(volume.mounted ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.name).lineLimit(1)
                    Text(volume.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                moreMenu
            }
            if volume.mounted && !volume.supportsFlags {
                Text("\(volume.fileSystem.uppercased().isEmpty ? "该文件系统" : volume.fileSystem.uppercased()) 不支持隐藏标志（需 APFS/HFS+）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if volume.mounted && !volume.ownedByMe {
                Text("卷根属主不是当前用户，先「修复权限」才能改桌面图标")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            // 入口位置：留空就在用户目录建与卷同名的符号链接
            HStack(spacing: 6) {
                TextField("入口位置（留空 = ~/\(volume.name)）",
                          text: Binding(
                            get: { state.entryPaths[volume.uuid.uppercased()] ?? "" },
                            set: { state.setEntryPath($0, for: volume) }
                          ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 210)
                Button("创建入口") {
                    state.createEntry(volume, at: state.entryPaths[volume.uuid.uppercased()] ?? "")
                }
                .font(.caption)
                .disabled(!volume.mounted)
            }
        }
        .padding(.vertical, 2)
    }

    private var moreMenu: some View {
        Menu {
            if volume.mounted {
                Button(volume.hidden ? "显示桌面图标" : "隐藏桌面图标") {
                    state.toggleHidden(volume)
                }
                .disabled(!volume.supportsFlags || !volume.ownedByMe)
                Button(volume.nobrowse ? "在访达中恢复显示（取消 nobrowse）" : "在访达中隐藏（nobrowse 重挂）") {
                    state.toggleNobrowse(volume)
                }
                Button("修复权限（把盘交还当前用户）") { state.fixOwner(volume) }
            } else if !volume.deviceNode.isEmpty {
                Button("挂载") { state.mount(volume) }
            }
            Divider()
            if volume.registered {
                Button("取消登记回挂") { state.unregister(volume) }
            } else {
                Button("登记回挂") { state.register(volume) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
