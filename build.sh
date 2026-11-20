#!/bin/bash
# 构建 DiskButler.app（SwiftPM + 手工组装 App 包，无需 Xcode 工程）
# 用法：./build.sh            生成 build/DiskButler.app
#       ./build.sh --install  生成后安装到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${BUILD_CONFIGURATION:-release}"
case "$CONFIG" in
    release|debug) ;;
    *) echo "不支持的构建配置：$CONFIG（仅支持 release/debug）" >&2; exit 2 ;;
esac

echo "—— 编译（${CONFIG}）——"
# 构建缓存放在本机缓存目录：外置卷上 llbuild 的 build.db 会报 disk I/O error
SCRATCH="${DISKBUTLER_SCRATCH:-$HOME/Library/Caches/DiskButlerBuild}"
export TMPDIR="${TMPDIR:-/tmp}"
swift build -c "$CONFIG" --product DiskButler --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path --scratch-path "$SCRATCH")"

APP="build/DiskButler.app"
# 原地覆盖而不是 rm -rf：某些环境下删除已签名的 App 包会报 Cross-device link
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiskButler" "$APP/Contents/MacOS/DiskButler"
# 图标（由 make_icon.sh 生成）
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>DiskButler</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.diskbutler</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DiskButler</string>
    <key>CFBundleDisplayName</key>
    <string>DiskButler</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>用于在「下载」文件夹里创建指向内存盘 DownloadsRAM 的链接</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>用于修改外置磁盘卷的隐藏标志与属主</string>
</dict>
</plist>
PLIST

# ad-hoc 签名：本机使用足够，不需要开发者账号
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "✅ 已生成：$PWD/$APP"

if [ "${1:-}" = "--install" ]; then
    echo "—— 安装到 /Applications ——"
    rm -rf "/Applications/DiskButler.app"
    cp -R "$APP" "/Applications/DiskButler.app"
    open "/Applications/DiskButler.app"
    echo "✅ 已安装并启动：/Applications/DiskButler.app"
fi
