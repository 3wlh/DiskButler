# DiskButler

DiskButler 是一款 macOS 菜单栏磁盘管理工具，支持外置磁盘回挂、访达隐藏、桌面图标控制、防止推出，以及内存盘和目录链接管理。

## 功能

- **外置磁盘**：登记后自动回挂，支持 nobrowse 挂载、桌面图标显示/隐藏、入口链接和权限修复。
- **防止推出**：通过 DiskArbitration 拦截登记卷的卸载与推出。
- **内存盘**：可调整容量，默认物理内存的 1/4；由「自动创建」开关控制挂载与卸载，支持目录到链接位置的映射。
- **登录前工作**：root 守护在登录前创建内存盘、回挂登记卷；登录事件发生后自动启动菜单栏 App 并补齐用户入口。
- **未登录挂载硬盘**：可切换系统 `AutomountDisksWithoutUserLogin` 设置。
- **事件驱动**：使用 vnode、notifyd、SystemConfiguration 和 DiskArbitration，无常驻轮询。

## 安装

1. 打开 DMG，将 `DiskButler.app` 拖到 `Applications`。
2. 打开“终端”，执行：

   ```bash
   xattr -cr "/Applications/DiskButler.app"
   ```

3. 从 Applications 打开 DiskButler。
4. 在菜单栏面板中开启「开机启动」，按提示完成一次管理员授权。

当前为 ad-hoc 签名的内测构建，未经过 Apple 公证。若修改外置卷属主时被系统拒绝，请在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中允许 DiskButler。

## 本地构建

要求：macOS 15 或更高版本，已安装 Xcode Command Line Tools。

```bash
./build.sh
```

构建产物：

- `build/DiskButler.app`
- `dist/DiskButler.dmg`

DMG 自动包含 App、Applications 快捷方式和安装说明。

安装并启动：

```bash
./build.sh --install
```

Debug 构建：

```bash
BUILD_CONFIGURATION=debug ./build.sh
```

## 配置

所有设置集中保存在：

```text
/Library/Application Support/DiskButler/DiskButler.json
```

## GitHub Actions

在 **Actions → Package macOS → Run workflow** 中手动触发，可选择 `release` 或 `debug`。工作流分别构建 arm64、x86_64 DMG，上传 Artifacts 并发布到 GitHub Releases。
