#!/bin/bash
# 编译「雷霆扫描.app」并安装到桌面（旧版会先移到废纸篓）
# 用法：bash build.sh [安装位置，默认 ~/Desktop/雷霆扫描.app]
set -e
cd "$(dirname "$0")"
DEST="${1:-$HOME/Desktop/雷霆扫描.app}"
APP="build/雷霆扫描.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译中（Intel + Apple 芯片）…"
swiftc -O -parse-as-library -target x86_64-apple-macos13.0 ScanApp.swift -o build/Scanner-x86_64
swiftc -O -parse-as-library -target arm64-apple-macos13.0 ScanApp.swift -o build/Scanner-arm64
lipo -create build/Scanner-x86_64 build/Scanner-arm64 -output "$APP/Contents/MacOS/Scanner"

if [ ! -f AppIcon.icns ]; then
  echo "生成图标…"
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  swift make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    d=$((s * 2))
    sips -z $d $d build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Scanner</string>
  <key>CFBundleIdentifier</key><string>local.scanner.escl</string>
  <key>CFBundleName</key><string>雷霆扫描</string>
  <key>CFBundleDisplayName</key><string>雷霆扫描</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSLocalNetworkUsageDescription</key><string>连接局域网里的扫描仪</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

if [ -e "$DEST" ]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$DEST\"" >/dev/null
fi
ditto "$APP" "$DEST"
echo "已安装：$DEST"
