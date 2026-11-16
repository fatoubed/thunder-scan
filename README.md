# 雷霆扫描

一个 macOS 上的网络扫描小工具：直接通过局域网连接支持 **eSCL（AirPrint 扫描）** 的联网一体机，一页一页连续扫描，自动去阴影、裁边、转正，最后存成 PDF 或 JPG。

不依赖打印机厂商驱动，也不依赖 Bonjour 自动发现（开着 ClashX 等代理软件时系统常常找不到打印机，这里会直接按网段探测）。

## 功能

- **扫描设置**：来源（自动 / 玻璃板 / 送纸器）、彩色 / 灰度 / 黑白、75–600 dpi、A4 / Letter / 整个玻璃板
- **自动适配扫描仪**：扫描前读取扫描仪能力，不支持的分辨率、超出范围的尺寸会自动调整
- **背景处理**
  - 文档：按局部背景亮度归一化，去掉阴影，背景变纯白，表格底纹保留
  - 证件/照片：只把接近白色且无彩色的像素变纯白，护照、证件的彩色底纹不受影响
- **自动裁掉四周空白**：适合护照、证件、小票
- **去小污点**：去掉孤立的灰尘点，阈值按分辨率换算
- **自动转正**：用系统文字识别（Vision）判断文字方向，纸放倒、放横都能转正
- **多页管理**：每页可旋转、调整顺序、删除、放大预览
- **输出**：存成多页 PDF（JPEG 压缩，三档质量）或每页一张 JPG；可选保存文件夹
- **插入到已有 PDF**：把扫好的页插进现成 PDF 的指定位置（原文件先移到废纸篓备份）
- **自动查找扫描仪**：在本机所在网段里探测 eSCL 设备

## 系统要求

- macOS 13 Ventura 或更新，Intel / Apple 芯片通用
- 支持 eSCL（AirPrint 扫描）的联网一体机。目前只在 HP Color LaserJet MFP M277dw 上实测过。

## 编译

只需要 Xcode 命令行工具（`xcode-select --install`），不需要 Xcode 工程。

```bash
bash build.sh      # 编译通用版（x86_64 + arm64），安装到 ~/Desktop/雷霆扫描.app
bash package.sh    # 编译并打包成 ~/Desktop/雷霆扫描-安装包.dmg
```

`build.sh` 可以带一个参数指定安装位置，例如 `bash build.sh /Applications/雷霆扫描.app`。

图标由 `make_icon.swift` 生成；删掉 `AppIcon.icns` 后再运行 `build.sh` 会重新生成。

## 命令行（调试用）

```bash
Scanner --discover                                   # 查找局域网里的扫描仪
Scanner --scan out.pdf [host=IP] [dpi=300] [bg=document|light|off] [color=color|gray|bw] [crop=1] [rot=auto]
Scanner --process in.pdf|in.jpg out.pdf [同上处理选项]
```

`Scanner` 在 `雷霆扫描.app/Contents/MacOS/` 里。

## 首次打开

没有做苹果开发者认证，第一次打开会被 Gatekeeper 拦下：右键 → 打开；macOS 15 及以后需要到「系统设置 → 隐私与安全性」点「仍要打开」。详见 [使用说明.txt](使用说明.txt)。

## 文件

| 文件 | 说明 |
| --- | --- |
| `ScanApp.swift` | 全部源码（SwiftUI 界面、eSCL 协议、图像处理、导出） |
| `build.sh` | 编译、生成 Info.plist、ad-hoc 签名、安装 |
| `package.sh` | 打包 DMG |
| `make_icon.swift` | 生成图标 |
| `使用说明.txt` | 给最终用户的中文说明（会放进 DMG） |
