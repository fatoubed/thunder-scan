#!/bin/bash
# 编译并打包成 DMG 安装包（输出到 build/ 目录）：bash package.sh
set -e
cd "$(dirname "$0")"
bash build.sh
STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto build/雷霆扫描.app "$STAGE/雷霆扫描.app"
ln -s /Applications "$STAGE/应用程序"
cp 使用说明.txt "$STAGE/使用说明.txt"
OUT="$PWD/build/雷霆扫描-安装包.dmg"
rm -f "$OUT"
hdiutil create -volname "雷霆扫描" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "安装包：$OUT"
