#!/bin/bash
# 生成 App 图标：Swift/AppKit 画 1024px 母图，再经 sips + iconutil 产出 AppIcon.icns
# 用法：./make_icon.sh   （只需在改图标时运行，产物在 Resources/AppIcon.icns）
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Resources

TMP="$(mktemp -d /tmp/diskbutler-icon.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/icon.swift" <<'SWIFT'
import AppKit

let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// 背景：macOS 风格圆角方块 + 蓝色纵向渐变
let bgRect = NSRect(x: 24, y: 24, width: side - 48, height: side - 48)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 224, yRadius: 224)
NSGradient(colors: [rgb(86, 148, 250), rgb(24, 78, 190)])!
    .draw(in: bgPath, angle: -90)

// 顶部一点高光，让图标不那么平
let gloss = NSBezierPath(roundedRect: NSRect(x: 24, y: side / 2, width: side - 48, height: side / 2 - 24),
                         xRadius: 224, yRadius: 224)
rgb(255, 255, 255, 0.08).setFill()
gloss.fill()

// 外置硬盘主体（白色，带投影）
let drive = NSRect(x: 232, y: 348, width: 560, height: 300)
let drivePath = NSBezierPath(roundedRect: drive, xRadius: 52, yRadius: 52)
let shadow = NSShadow()
shadow.shadowColor = rgb(8, 24, 60, 0.35)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -12)
ctx.saveGState()
shadow.set()
rgb(248, 250, 253).setFill()
drivePath.fill()
ctx.restoreGState()

// 硬盘前脸分割线 + 状态灯
let sep = NSBezierPath()
sep.move(to: NSPoint(x: drive.minX + 44, y: drive.minY + 86))
sep.line(to: NSPoint(x: drive.maxX - 44, y: drive.minY + 86))
sep.lineWidth = 7
rgb(198, 210, 230).setStroke()
sep.stroke()
rgb(52, 199, 123).setFill()
NSBezierPath(ovalIn: NSRect(x: drive.maxX - 250, y: drive.minY + 34, width: 26, height: 26)).fill()

// 右下角闪电徽章：代表内存盘的速度
let badge = NSRect(x: 610, y: 218, width: 230, height: 230)
let badgePath = NSBezierPath(ovalIn: badge)
ctx.saveGState()
shadow.set()
NSGradient(colors: [rgb(253, 205, 90), rgb(240, 152, 32)])!
    .draw(in: badgePath, angle: -90)
ctx.restoreGState()

let bolt = NSBezierPath()
func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: badge.minX + x * badge.width, y: badge.minY + y * badge.height)
}
bolt.move(to: pt(0.58, 0.88))
bolt.line(to: pt(0.28, 0.46))
bolt.line(to: pt(0.46, 0.46))
bolt.line(to: pt(0.40, 0.12))
bolt.line(to: pt(0.72, 0.56))
bolt.line(to: pt(0.53, 0.56))
bolt.close()
NSColor.white.setFill()
bolt.fill()

image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
SWIFT

swift "$TMP/icon.swift" "$TMP/icon_1024.png"

# 组装 iconset → icns
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for spec in "16:16:icon_16x16" "32:16:icon_16x16@2x" "32:32:icon_32x32" "64:32:icon_32x32@2x" \
            "128:128:icon_128x128" "256:128:icon_128x128@2x" "256:256:icon_256x256" \
            "512:256:icon_256x256@2x" "512:512:icon_512x512" "1024:512:icon_512x512@2x"; do
    px="${spec%%:*}"; rest="${spec#*:}"; base="${rest#*:}"
    sips -z "$px" "$px" "$TMP/icon_1024.png" --out "$SET/${base}.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "✅ 已生成：$PWD/Resources/AppIcon.icns"
