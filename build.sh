#!/bin/bash
# 编译「雷霆扫描.app」并安装到桌面（旧版会先移到废纸篓）
# 用法：bash build.sh [安装位置，默认 ~/Desktop/雷霆扫描.app]
#       指定 SDK：SDKROOT=SDK路径 bash build.sh
set -e
cd "$(dirname "$0")"
DEST="${1:-$HOME/Desktop/雷霆扫描.app}"
APP="build/雷霆扫描.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 选择 SDK：macOS 27 SDK 起 SwiftUI 的 @State 改为宏，只装命令行工具时缺少宏插件
# （报错「plugin for module 'SwiftUIMacros' not found」）。此时改用本机较旧的 macOS SDK。
# 已设置 SDKROOT 时不检测。
sdk_ok() {
  SDKROOT="$1" swiftc -parse-as-library -target arm64-apple-macos13.0 -typecheck build/sdk_probe.swift >/dev/null 2>&1
}
if [ -z "$SDKROOT" ]; then
  printf 'import SwiftUI\nstruct P: View {\n  @State var n = 0\n  var body: some View { Button("") { n += 1 } }\n}\n' > build/sdk_probe.swift
  DEFAULT_SDK="$(xcrun --show-sdk-path)"
  if ! sdk_ok "$DEFAULT_SDK"; then
    SDK_DIR="$(dirname "$DEFAULT_SDK")"
    TRIED=" $(cd "$DEFAULT_SDK" && pwd -P) "
    for name in $(ls "$SDK_DIR" | grep -E '^MacOSX[0-9.]+\.sdk$' | sort -rV); do
      sdk="$(cd "$SDK_DIR/$name" && pwd -P)"
      case "$TRIED" in *" $sdk "*) continue ;; esac
      TRIED="$TRIED$sdk "
      if sdk_ok "$sdk"; then export SDKROOT="$sdk"; break; fi
    done
    if [ -z "$SDKROOT" ]; then
      echo "错误：默认 SDK 无法编译 SwiftUI 代码（可能缺少 SwiftUIMacros 宏插件），本机也没有可用的其他 macOS SDK。" >&2
      echo "请安装完整的 Xcode，或用 SDKROOT=SDK路径 bash build.sh 指定 SDK。" >&2
      exit 1
    fi
    echo "默认 SDK 缺少 SwiftUI 宏插件，改用 $(basename "$SDKROOT")"
  fi
fi

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
# 运行时 Dock 图标跟随深浅色（由 make_icon_v2.py 生成）
for f in AppIcon-light.png AppIcon-dark.png; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/$f"; done

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
  <key>CFBundleShortVersionString</key><string>2.2</string>
  <key>CFBundleVersion</key><string>4</string>
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
