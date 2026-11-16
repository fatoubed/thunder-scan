// 雷霆扫描 —— macOS 网络扫描小工具（eSCL / AirPrint 扫描协议）
// 编译：bash build.sh   （生成桌面上的「雷霆扫描.app」）
// 命令行测试：Scanner --process 输入.pdf|jpg 输出.pdf [bg=off|light|document] [color=color|gray|bw] [crop=0|1] [speck=0|1] [dpi=300]
//            Scanner --scan 输出.pdf [同上选项] [src=auto|platen|feeder] [host=IP] [paper=a4|letter|full]
//            Scanner --discover

import SwiftUI
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - 选项

enum ColorChoice: String, CaseIterable, Identifiable {
    case color = "彩色", gray = "灰度", bw = "黑白"
    var id: String { rawValue }
    var label: String { rawValue }
}

enum SourceChoice: String, CaseIterable, Identifiable {
    case auto = "自动", platen = "玻璃板", feeder = "送纸器"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自动选择"
        case .platen: return "平板"
        case .feeder: return "自动进纸器"
        }
    }
}

enum PaperChoice: String, CaseIterable, Identifiable {
    case a4 = "A4", letter = "Letter", full = "整个玻璃板"
    var id: String { rawValue }
    var label: String { self == .full ? "最大扫描区域" : rawValue }
    /// 单位：1/300 英寸
    var size: (Int, Int) {
        switch self {
        case .a4: return (2480, 3508)
        case .letter: return (2550, 3300)
        case .full: return (2550, 3508)
        }
    }
}

enum BgChoice: String, CaseIterable, Identifiable {
    case off = "关闭（保持原样）"
    case light = "证件/照片：白底变纯白，保留颜色"
    case document = "文档：去阴影，背景纯白"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "不处理"
        case .light: return "证件与照片：背景纯白，保留彩色"
        case .document: return "文档：去除阴影，背景纯白"
        }
    }
}

enum QualityChoice: String, CaseIterable, Identifiable {
    case high = "高质量", standard = "标准", small = "小文件"
    var id: String { rawValue }
    var label: String { self == .small ? "高压缩（文件较小）" : rawValue }
    var jpeg: Double {
        switch self {
        case .high: return 0.92
        case .standard: return 0.8
        case .small: return 0.6
        }
    }
}

enum FormatChoice: String, CaseIterable, Identifiable {
    case pdf = "PDF", jpg = "JPG"
    var id: String { rawValue }
    var label: String { rawValue }
}

struct ProcSettings: Equatable {
    var bg: BgChoice
    var color: ColorChoice
    var autoCrop: Bool
    var despeckle: Bool
}

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - 图像处理

enum ImageOps {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let grayCS = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

    @inline(__always) static func lum(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (Int(r) * 77 + Int(g) * 150 + Int(b) * 29) >> 8
    }

    static func rgba(_ img: CGImage) -> (Int, Int, [UInt8]) {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, buf)
    }

    static func makeImage(_ w: Int, _ h: Int, _ buf: [UInt8], gray: Bool) -> CGImage {
        if gray {
            var g = [UInt8](repeating: 0, count: w * h)
            buf.withUnsafeBufferPointer { p in
                g.withUnsafeMutableBufferPointer { q in
                    for i in 0..<(w * h) { q[i] = UInt8(lum(p[i * 4], p[i * 4 + 1], p[i * 4 + 2])) }
                }
            }
            let prov = CGDataProvider(data: Data(g) as CFData)!
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                           space: grayCS, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        }
        let prov = CGDataProvider(data: Data(buf) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func percentile(_ hist: [Int], _ total: Int, _ p: Double) -> Int {
        let target = Int(Double(total) * p)
        var acc = 0
        for v in 0..<256 {
            acc += hist[v]
            if acc >= target { return v }
        }
        return 255
    }

    /// 主流程：去背景 → 黑白化 → 去污点 → 自动裁切 → 转灰度
    static func process(_ img: CGImage, dpi: Int, s: ProcSettings) -> CGImage {
        if s.bg == .off && !s.autoCrop && s.color == .color { return img }
        var (w, h, px) = rgba(img)
        if s.bg == .document || s.color == .bw {
            normalizeDocument(&px, w, h, dpi: dpi)
        } else if s.bg == .light {
            whitenLight(&px, w, h)
        }
        if s.color == .bw { threshold(&px, w * h) }
        if s.despeckle && (s.bg == .document || s.color == .bw) { despeckle(&px, w, h, dpi: dpi) }
        if s.autoCrop, let r = contentRect(px, w, h, dpi: dpi) {
            px = crop(px, w, r)
            w = r.2; h = r.3
        }
        return makeImage(w, h, px, gray: s.color != .color)
    }

    /// 文档模式：按局部背景亮度做归一化（去掉阴影/发灰），再拉色阶让纸面变纯白
    static func normalizeDocument(_ px: inout [UInt8], _ w: Int, _ h: Int, dpi: Int) {
        let n = w * h
        var lumA = [UInt8](repeating: 0, count: n)
        var hist = [Int](repeating: 0, count: 256)
        px.withUnsafeBufferPointer { p in
            lumA.withUnsafeMutableBufferPointer { l in
                for i in 0..<n {
                    let v = lum(p[i * 4], p[i * 4 + 1], p[i * 4 + 2])
                    l[i] = UInt8(v)
                    hist[v] += 1
                }
            }
        }
        let paper = max(percentile(hist, n, 0.95), 120)
        let floorBg = Double(paper) * 0.55
        // 背景网格：每块约 3 厘米，取块内 95% 分位亮度当作纸面亮度
        let B = max(32, dpi * 6 / 5)
        let gw = (w + B - 1) / B, gh = (h + B - 1) / B
        var grid = [Double](repeating: Double(paper), count: gw * gh)
        var bh = [Int](repeating: 0, count: 256)
        lumA.withUnsafeBufferPointer { l in
            for gy in 0..<gh {
                for gx in 0..<gw {
                    for k in 0..<256 { bh[k] = 0 }
                    let x0 = gx * B, x1 = min(w, x0 + B), y0 = gy * B, y1 = min(h, y0 + B)
                    var cnt = 0
                    var y = y0
                    while y < y1 {
                        var x = x0
                        let row = y * w
                        while x < x1 { bh[Int(l[row + x])] += 1; cnt += 1; x += 2 }
                        y += 2
                    }
                    let v = Double(percentile(bh, cnt, 0.95))
                    grid[gy * gw + gx] = min(255, max(floorBg, v))
                }
            }
        }
        // 轻度平滑（中心加权）
        var sm = grid
        for gy in 0..<gh {
            for gx in 0..<gw {
                var s = grid[gy * gw + gx] * 4, c = 4.0
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let yy = gy + dy, xx = gx + dx
                        if yy >= 0 && yy < gh && xx >= 0 && xx < gw { s += grid[yy * gw + xx]; c += 1 }
                    }
                }
                sm[gy * gw + gx] = s / c
            }
        }
        // 双线性插值得到每个像素的背景亮度，做除法归一化 + 色阶
        var cx0 = [Int](repeating: 0, count: w), cx1 = [Int](repeating: 0, count: w), ctx = [Double](repeating: 0, count: w)
        for x in 0..<w {
            let f = min(max((Double(x) - Double(B) / 2) / Double(B), 0), Double(gw - 1))
            let i0 = Int(f)
            cx0[x] = i0; cx1[x] = min(i0 + 1, gw - 1); ctx[x] = f - Double(i0)
        }
        let K = 18.0, W = 232.0, S = 255.0 / (W - K)
        var rowBg = [Double](repeating: 0, count: gw)
        px.withUnsafeMutableBufferPointer { p in
            for y in 0..<h {
                let f = min(max((Double(y) - Double(B) / 2) / Double(B), 0), Double(gh - 1))
                let j0 = Int(f), j1 = min(j0 + 1, gh - 1), ty = f - Double(j0)
                for gx in 0..<gw { rowBg[gx] = sm[j0 * gw + gx] * (1 - ty) + sm[j1 * gw + gx] * ty }
                for x in 0..<w {
                    let bg = rowBg[cx0[x]] * (1 - ctx[x]) + rowBg[cx1[x]] * ctx[x]
                    let fac = 255.0 / max(bg, 1)
                    let i = (y * w + x) * 4
                    for c in 0..<3 {
                        let v = (Double(p[i + c]) * fac - K) * S
                        p[i + c] = UInt8(max(0, min(255, v)))
                    }
                }
            }
        }
    }

    /// 证件/照片模式：整体把纸白拉到 255，只把「接近白色且没有颜色」的像素变成纯白，彩色底纹保留
    static func whitenLight(_ px: inout [UInt8], _ w: Int, _ h: Int) {
        let n = w * h
        var hist = [Int](repeating: 0, count: 256)
        px.withUnsafeBufferPointer { p in
            for i in 0..<n { hist[lum(p[i * 4], p[i * 4 + 1], p[i * 4 + 2])] += 1 }
        }
        let paper = max(percentile(hist, n, 0.98), 150)
        let fac = min(255.0 / Double(paper), 1.25)
        px.withUnsafeMutableBufferPointer { p in
            for i in 0..<n {
                let k = i * 4
                let r: Double = Swift.min(255.0, Double(p[k]) * fac)
                let g: Double = Swift.min(255.0, Double(p[k + 1]) * fac)
                let b: Double = Swift.min(255.0, Double(p[k + 2]) * fac)
                let L: Double = (r * 77.0 + g * 150.0 + b * 29.0) / 256.0
                let hi: Double = Swift.max(r, Swift.max(g, b))
                let lo: Double = Swift.min(r, Swift.min(g, b))
                var t: Double = 0
                if hi - lo < 20.0 {
                    if L >= 228.0 { t = 1 } else if L > 208.0 { t = (L - 208.0) / 20.0 }
                }
                let r2: Double = r + (255.0 - r) * t
                let g2: Double = g + (255.0 - g) * t
                let b2: Double = b + (255.0 - b) * t
                p[k] = UInt8(r2)
                p[k + 1] = UInt8(g2)
                p[k + 2] = UInt8(b2)
            }
        }
    }

    static func threshold(_ px: inout [UInt8], _ n: Int) {
        px.withUnsafeMutableBufferPointer { p in
            for i in 0..<n {
                let k = i * 4
                let v: UInt8 = lum(p[k], p[k + 1], p[k + 2]) < 165 ? 0 : 255
                p[k] = v; p[k + 1] = v; p[k + 2] = v
            }
        }
    }

    /// 去掉孤立的小黑点（灰尘），面积阈值按分辨率换算，句号这类正常笔画不会被删
    static func despeckle(_ px: inout [UInt8], _ w: Int, _ h: Int, dpi: Int) {
        let maxArea = max(2, Int(8.0 * pow(Double(dpi) / 300.0, 2)))
        let n = w * h
        var mask = [UInt8](repeating: 0, count: n)
        px.withUnsafeBufferPointer { p in
            for i in 0..<n where lum(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]) < 200 { mask[i] = 1 }
        }
        var stack: [Int] = []
        var comp: [Int] = []
        stack.reserveCapacity(4096)
        px.withUnsafeMutableBufferPointer { p in
            mask.withUnsafeMutableBufferPointer { m in
                for i in 0..<n where m[i] == 1 {
                    m[i] = 2
                    stack.removeAll(keepingCapacity: true)
                    comp.removeAll(keepingCapacity: true)
                    stack.append(i)
                    var big = false
                    while let j = stack.popLast() {
                        if !big {
                            comp.append(j)
                            if comp.count > maxArea { big = true }
                        }
                        let x = j % w, y = j / w
                        for dy in -1...1 {
                            let yy = y + dy
                            if yy < 0 || yy >= h { continue }
                            for dx in -1...1 {
                                let xx = x + dx
                                if xx < 0 || xx >= w { continue }
                                let k = yy * w + xx
                                if m[k] == 1 { m[k] = 2; stack.append(k) }
                            }
                        }
                    }
                    if !big {
                        for j in comp { p[j * 4] = 255; p[j * 4 + 1] = 255; p[j * 4 + 2] = 255 }
                    }
                }
            }
        }
    }

    /// 找内容区域（忽略最外圈约 3mm 的扫描仪边缘阴影），返回 (x, y, w, h)
    static func contentRect(_ px: [UInt8], _ w: Int, _ h: Int, dpi: Int) -> (Int, Int, Int, Int)? {
        let border = max(4, dpi / 8)
        guard w > border * 4, h > border * 4 else { return nil }
        var rowCnt = [Int](repeating: 0, count: h), colCnt = [Int](repeating: 0, count: w)
        px.withUnsafeBufferPointer { p in
            for y in border..<(h - border) {
                for x in border..<(w - border) {
                    let i = (y * w + x) * 4
                    if lum(p[i], p[i + 1], p[i + 2]) < 236 { rowCnt[y] += 1; colCnt[x] += 1 }
                }
            }
        }
        let rowMin = max(3, (w - 2 * border) / 300), colMin = max(3, (h - 2 * border) / 300)
        func first(_ a: [Int], _ lo: Int, _ hi: Int, _ m: Int) -> Int? {
            var i = lo
            while i + 2 < hi { if a[i] >= m && a[i + 1] >= m && a[i + 2] >= m { return i }; i += 1 }
            return nil
        }
        func last(_ a: [Int], _ lo: Int, _ hi: Int, _ m: Int) -> Int? {
            var i = hi - 1
            while i - 2 >= lo { if a[i] >= m && a[i - 1] >= m && a[i - 2] >= m { return i }; i -= 1 }
            return nil
        }
        guard let top = first(rowCnt, border, h - border, rowMin),
              let bottom = last(rowCnt, border, h - border, rowMin),
              let left = first(colCnt, border, w - border, colMin),
              let right = last(colCnt, border, w - border, colMin),
              bottom > top, right > left else { return nil }
        let m = dpi / 10
        let x0 = max(0, left - m), y0 = max(0, top - m)
        let x1 = min(w, right + m + 1), y1 = min(h, bottom + m + 1)
        if Double((x1 - x0) * (y1 - y0)) > Double(w * h) * 0.92 { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    static func crop(_ px: [UInt8], _ w: Int, _ r: (Int, Int, Int, Int)) -> [UInt8] {
        let (x0, y0, cw, ch) = r
        var out = [UInt8](repeating: 255, count: cw * ch * 4)
        px.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<ch {
                    let src = ((y0 + y) * w + x0) * 4, dst = y * cw * 4
                    for k in 0..<(cw * 4) { o[dst + k] = p[src + k] }
                }
            }
        }
        return out
    }

    /// 顺时针旋转 deg 度（90 的倍数）
    static func rotate(_ img: CGImage, _ deg: Int) -> CGImage {
        let d = ((deg % 360) + 360) % 360
        if d == 0 { return img }
        let w = img.width, h = img.height
        let nw = d == 180 ? w : h, nh = d == 180 ? h : w
        let gray = img.colorSpace?.model == .monochrome
        let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: gray ? grayCS : srgb,
                            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: -CGFloat(d) * .pi / 180)
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()!
    }

    static func scaled(_ img: CGImage, maxSide: Int) -> CGImage {
        let s = Double(maxSide) / Double(max(img.width, img.height))
        if s >= 1 { return img }
        let w = max(1, Int(Double(img.width) * s)), h = max(1, Int(Double(img.height) * s))
        let gray = img.colorSpace?.model == .monochrome
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: gray ? grayCS : srgb,
                            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func jpegData(_ img: CGImage, quality: Double, dpi: Int) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// 用文字识别判断页面朝向，返回需要顺时针旋转的角度（0/90/180/270）
    static func detectRotation(_ img: CGImage) -> Int {
        let base = scaled(img, maxSide: 1600)
        var scores: [Int: Double] = [:]
        for d in [0, 90, 180, 270] {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: rotate(base, d), options: [:]).perform([req])
            scores[d] = (req.results ?? []).reduce(0.0) { a, o in
                let c = o.topCandidates(1).first
                return a + Double(c?.confidence ?? 0) * Double(c?.string.filter { $0.isLetter || $0.isNumber }.count ?? 0)
            }
        }
        let best = scores.max { $0.value < $1.value }!
        // 文字太少或优势不明显就不转
        if best.key == 0 || best.value < 15 || best.value < (scores[0] ?? 0) * 1.3 { return 0 }
        return best.key
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 把 PDF 某一页渲染成图片（命令行测试用）
    static func renderPDF(_ url: URL, page: Int, dpi: Int) -> CGImage? {
        guard let doc = PDFDocument(url: url), let pg = doc.page(at: page) else { return nil }
        let box = pg.bounds(for: .mediaBox)
        let s = Double(dpi) / 72
        let w = Int(box.width * s), h = Int(box.height * s)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        pg.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}

// MARK: - 导出

enum Exporter {
    struct Item { let image: CGImage; let dpi: Int; let rotation: Int }

    static func uniqueURL(_ dir: URL, _ name: String, _ ext: String) -> URL {
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) (\(i)).\(ext)")
            i += 1
        }
        return url
    }

    static func writePDF(_ items: [Item], quality: Double, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw AppError("无法创建 PDF 文件：\(url.path)") }
        for it in items {
            let img = ImageOps.rotate(it.image, it.rotation)
            let data = ImageOps.jpegData(img, quality: quality, dpi: it.dpi)
            guard let prov = CGDataProvider(data: data as CFData),
                  let jimg = CGImage(jpegDataProviderSource: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            var box = CGRect(x: 0, y: 0, width: CGFloat(img.width) * 72 / CGFloat(it.dpi), height: CGFloat(img.height) * 72 / CGFloat(it.dpi))
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            ctx.draw(jimg, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func export(_ items: [Item], format: FormatChoice, quality: Double, dir: URL, name: String) throws -> [URL] {
        if format == .pdf {
            let url = uniqueURL(dir, name, "pdf")
            try writePDF(items, quality: quality, to: url)
            return [url]
        }
        var urls: [URL] = []
        for (i, it) in items.enumerated() {
            let url = uniqueURL(dir, items.count == 1 ? name : "\(name)_\(i + 1)", "jpg")
            let img = ImageOps.rotate(it.image, it.rotation)
            try ImageOps.jpegData(img, quality: quality, dpi: it.dpi).write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// 插入到已有 PDF：原文件先移到废纸篓备份，再写入新版本
    static func insert(_ items: [Item], quality: Double, into target: URL, after: Int) throws {
        let tmpNew = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: tmpNew) }
        try writePDF(items, quality: quality, to: tmpNew)
        guard let doc = PDFDocument(url: target) else { throw AppError("无法打开 PDF 文件：\(target.lastPathComponent)") }
        if doc.isLocked { throw AppError("该 PDF 文件受密码保护，无法插入页面。") }
        guard let add = PDFDocument(url: tmpNew) else { throw AppError("生成扫描页面失败。") }
        var at = min(max(0, after), doc.pageCount)
        for i in 0..<add.pageCount {
            if let p = add.page(at: i) { doc.insert(p, at: at); at += 1 }
        }
        let tmpOut = target.deletingLastPathComponent().appendingPathComponent(".扫描临时-\(UUID().uuidString).pdf")
        guard doc.write(to: tmpOut) else { throw AppError("写入失败，请检查目标文件夹的写入权限。") }
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            try FileManager.default.moveItem(at: tmpOut, to: target)
        } catch {
            try? FileManager.default.removeItem(at: tmpOut)
            throw error
        }
    }
}

// MARK: - eSCL 扫描协议

struct ScannerStatus { var state: String; var adfLoaded: Bool }

struct FoundScanner: Identifiable { let id: String; let model: String }

struct ESCL {
    let host: String

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // 绕开代理（ClashX 等），直连局域网
        c.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    var base: String { "http://\(host)" }

    func get(_ pathOrURL: String, timeout: Double) async throws -> (Data, Int) {
        let s = pathOrURL.hasPrefix("http") ? pathOrURL : base + pathOrURL
        guard let url = URL(string: s) else { throw AppError("扫描仪地址无效：\(host)") }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (d, r) = try await Self.session.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func tag(_ s: String, _ name: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    func status() async throws -> ScannerStatus {
        let (d, code) = try await get("/eSCL/ScannerStatus", timeout: 4)
        guard code == 200, let s = String(data: d, encoding: .utf8) else { throw AppError("扫描仪未响应（HTTP \(code)）。") }
        return ScannerStatus(state: Self.tag(s, "pwg:State") ?? "", adfLoaded: s.contains("ScannerAdfLoaded"))
    }

    func model(timeout: Double) async -> String? {
        guard let (d, code) = try? await get("/eSCL/ScannerCapabilities", timeout: timeout), code == 200,
              let s = String(data: d, encoding: .utf8), s.contains("ScannerCapabilities") else { return nil }
        return Self.tag(s, "pwg:MakeAndModel") ?? "扫描仪"
    }

    /// 按这台扫描仪的能力调整分辨率和扫描区域（适配不同型号）
    func adjust(feeder: Bool, dpi: Int, width: Int, height: Int) async -> (Int, Int, Int) {
        var d = feeder ? min(dpi, 300) : dpi
        var w = width, h = height
        guard let (data, code) = try? await get("/eSCL/ScannerCapabilities", timeout: 6), code == 200,
              let s = String(data: data, encoding: .utf8),
              let sec = Self.tag(s, feeder ? "scan:Adf" : "scan:Platen") else { return (d, w, h) }
        if let mw = Int(Self.tag(sec, "scan:MaxWidth") ?? "") { w = min(w, mw) }
        if let mh = Int(Self.tag(sec, "scan:MaxHeight") ?? "") { h = min(h, mh) }
        var res = Set<Int>()
        var rest = sec[...]
        while let a = rest.range(of: "<scan:XResolution>"), let b = rest.range(of: "</scan:XResolution>", range: a.upperBound..<rest.endIndex) {
            if let v = Int(rest[a.upperBound..<b.lowerBound]) { res.insert(v) }
            rest = rest[b.upperBound...]
        }
        if !res.isEmpty && !res.contains(d) {
            d = res.filter { $0 <= dpi }.max() ?? res.min()!
        }
        return (d, w, h)
    }

    /// 扫描：玻璃板 1 页；送纸器一直取到没有纸为止。每拿到一页回调一次
    func scan(feeder: Bool, gray: Bool, dpi: Int, width: Int, height: Int,
              onPage: @escaping (Data) async -> Void) async throws -> Int {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
        <pwg:Version>2.5</pwg:Version>
        <pwg:ScanRegions><pwg:ScanRegion><pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
        <pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset><pwg:Width>\(width)</pwg:Width><pwg:Height>\(height)</pwg:Height>
        </pwg:ScanRegion></pwg:ScanRegions>
        <pwg:InputSource>\(feeder ? "Feeder" : "Platen")</pwg:InputSource>
        <scan:ColorMode>\(gray ? "Grayscale8" : "RGB24")</scan:ColorMode>
        <scan:XResolution>\(dpi)</scan:XResolution><scan:YResolution>\(dpi)</scan:YResolution>
        <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat><scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
        </scan:ScanSettings>
        """
        guard let url = URL(string: base + "/eSCL/ScanJobs") else { throw AppError("扫描仪地址无效：\(host)") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = xml.data(using: .utf8)

        var location: String?
        for _ in 0..<10 {
            let (_, resp) = try await Self.session.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 201, let loc = http?.value(forHTTPHeaderField: "Location") { location = loc; break }
            if code == 503 || code == 409 { try await Task.sleep(nanoseconds: 2_000_000_000); continue }
            throw AppError("扫描仪拒绝了扫描请求（HTTP \(code)），可能不支持当前的分辨率或来源。")
        }
        guard let loc = location else { throw AppError("扫描仪处于忙碌状态（可能正在打印），请稍后重试。") }
        let job = loc.hasPrefix("http") ? loc : base + loc

        var pages = 0, busy = 0
        while true {
            let (data, code) = try await get(job + "/NextDocument", timeout: 300)
            if code == 200 && !data.isEmpty {
                pages += 1
                busy = 0
                await onPage(data)
                if !feeder { break }
                continue
            }
            if code == 404 { break }
            if code == 503 && busy < 90 { busy += 1; try await Task.sleep(nanoseconds: 1_000_000_000); continue }
            if pages > 0 { break }
            throw AppError("获取扫描结果失败（HTTP \(code)）。")
        }
        if pages == 0 { throw AppError("未获取到扫描结果，请检查自动进纸器是否卡纸或缺纸。") }
        return pages
    }

    static func localPrefixes() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("en"), let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                let parts = ip.split(separator: ".")
                if parts.count == 4 {
                    let a = Int(parts[0]) ?? 0, b = Int(parts[1]) ?? 0
                    if a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) {
                        let prefix = parts[0...2].joined(separator: ".")
                        if !out.contains(prefix) { out.append(prefix) }
                    }
                }
            }
            p = ifa.ifa_next
        }
        return out
    }

    /// 在本机所在网段里逐个探测 eSCL 扫描仪（不依赖 Bonjour，ClashX 开着也能找到）
    static func discover() async -> [FoundScanner] {
        let prefixes = localPrefixes()
        return await withTaskGroup(of: FoundScanner?.self) { g in
            for pre in prefixes {
                for i in 1...254 {
                    let ip = "\(pre).\(i)"
                    g.addTask {
                        if let m = await ESCL(host: ip).model(timeout: 2) { return FoundScanner(id: ip, model: m) }
                        return nil
                    }
                }
            }
            var r: [FoundScanner] = []
            for await x in g { if let x = x { r.append(x) } }
            return r.sorted { $0.id < $1.id }
        }
    }
}

// MARK: - 数据模型

struct ScanPage: Identifiable {
    let id = UUID()
    let raw: CGImage
    let dpi: Int
    var rotation = 0
    var processed: CGImage?
    var small: CGImage?
    var thumb: NSImage?
    var processing = true
    var oriented = false
}

@MainActor
final class AppModel: ObservableObject {
    private let ud = UserDefaults.standard

    @Published var host: String {
        didSet {
            guard host != oldValue else { return }
            ud.set(host, forKey: "host"); online = nil; Task { await refreshStatus() }
        }
    }
    @Published var source: SourceChoice { didSet { ud.set(source.rawValue, forKey: "source") } }
    @Published var color: ColorChoice { didSet { ud.set(color.rawValue, forKey: "color"); reprocessAll() } }
    @Published var dpi: Int { didSet { ud.set(dpi, forKey: "dpi") } }
    @Published var paper: PaperChoice { didSet { ud.set(paper.rawValue, forKey: "paper") } }
    @Published var bg: BgChoice { didSet { ud.set(bg.rawValue, forKey: "bg"); reprocessAll() } }
    @Published var autoCrop: Bool { didSet { ud.set(autoCrop, forKey: "autoCrop"); reprocessAll() } }
    @Published var despeckle: Bool { didSet { ud.set(despeckle, forKey: "despeckle"); reprocessAll() } }
    @Published var autoRotate: Bool { didSet { ud.set(autoRotate, forKey: "autoRotate") } }
    @Published var quality: QualityChoice { didSet { ud.set(quality.rawValue, forKey: "quality") } }
    @Published var format: FormatChoice { didSet { ud.set(format.rawValue, forKey: "format") } }
    @Published var outputDir: String { didSet { ud.set(outputDir, forKey: "outputDir") } }
    @Published var revealAfterSave: Bool { didSet { ud.set(revealAfterSave, forKey: "reveal") } }
    @Published var clearAfterSave: Bool { didSet { ud.set(clearAfterSave, forKey: "clear") } }
    @Published var fileName = ""

    @Published var pages: [ScanPage] = []
    @Published var isScanning = false
    @Published var isSaving = false
    @Published var statusText = ""
    @Published var online: Bool?
    @Published var scannerState = ""
    @Published var adfLoaded = false
    @Published var found: [FoundScanner] = []
    @Published var searching = false
    @Published var previewID: UUID?
    @Published var alert: String?
    @Published var appendTarget: URL?
    @Published var appendPageCount = 0
    @Published var appendAfter = 0

    private var queue: [UUID] = []
    private var working = false
    private var polling = false
    static weak var shared: AppModel?

    init() {
        let ud = UserDefaults.standard
        func str<T: RawRepresentable>(_ k: String, _ d: T) -> T where T.RawValue == String {
            (ud.string(forKey: k)).flatMap { T(rawValue: $0) } ?? d
        }
        func bool(_ k: String, _ d: Bool) -> Bool { ud.object(forKey: k) == nil ? d : ud.bool(forKey: k) }
        host = ud.string(forKey: "host") ?? ""
        source = str("source", SourceChoice.auto)
        color = str("color", ColorChoice.color)
        let d = ud.integer(forKey: "dpi")
        dpi = [75, 200, 300, 600].contains(d) ? d : 300
        paper = str("paper", PaperChoice.a4)
        bg = str("bg", BgChoice.document)
        autoCrop = bool("autoCrop", false)
        despeckle = bool("despeckle", true)
        autoRotate = bool("autoRotate", true)
        quality = str("quality", QualityChoice.standard)
        format = str("format", FormatChoice.pdf)
        outputDir = ud.string(forKey: "outputDir") ?? (NSHomeDirectory() + "/Desktop")
        revealAfterSave = bool("reveal", true)
        clearAfterSave = bool("clear", true)
        AppModel.shared = self
        // 演示模式（README 截图用）：显示示例地址与在线状态，不连接真实设备，不改动已保存的设置
        if ProcessInfo.processInfo.environment["SCAN_DEMO"] != nil {
            demo = true
            host = "192.168.1.20"
            online = true
            scannerState = "Idle"
            found = [FoundScanner(id: "192.168.1.20", model: "HP Color LaserJet MFP M277dw")]
            statusText = "本次扫描 1 页，共 4 页"
        }
    }

    private var demo = false

    var settings: ProcSettings { ProcSettings(bg: bg, color: color, autoCrop: autoCrop, despeckle: despeckle) }
    var busy: Bool { isScanning || isSaving }
    var outputURL: URL { URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath, isDirectory: true) }
    var esc: ESCL { ESCL(host: host.trimmingCharacters(in: .whitespacesAndNewlines)) }

    // 状态轮询
    func startPolling() {
        guard !polling, !demo else { return }
        polling = true
        if host.trimmingCharacters(in: .whitespaces).isEmpty { discover(silent: true) }
        Task {
            while true {
                await refreshStatus()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func refreshStatus() async {
        if isScanning || demo { return }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { online = false; scannerState = ""; return }
        do {
            let st = try await esc.status()
            online = true; scannerState = st.state; adfLoaded = st.adfLoaded
        } catch {
            online = false; scannerState = ""; adfLoaded = false
        }
    }

    func discover(silent: Bool = false) {
        searching = true
        found = []
        if silent { statusText = "正在局域网中查找扫描仪…" }
        Task {
            let r = await ESCL.discover()
            found = r
            searching = false
            if r.isEmpty {
                let msg = "在本机所在网段中未找到扫描仪。请确认打印机已开机并与本机连接同一网络，或在左侧手动输入打印机的 IP 地址。"
                if silent { statusText = "未找到扫描仪，请手动输入地址" } else { alert = msg }
            } else if r.count == 1 || host.trimmingCharacters(in: .whitespaces).isEmpty {
                host = r[0].id
                statusText = r.count == 1 ? "已连接 \(r[0].model)（\(r[0].id)）" : "找到 \(r.count) 台扫描仪，已选用第一台，可在左侧更改"
            } else {
                statusText = "找到 \(r.count) 台扫描仪，请在左侧选择"
            }
        }
    }

    // 扫描
    func scan() {
        guard !busy else { return }
        isScanning = true
        statusText = "正在连接扫描仪…"
        Task {
            do {
                if host.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw AppError("尚未设置扫描仪。请点击左侧「自动查找扫描仪」，或手动输入打印机的 IP 地址。")
                }
                let e = esc
                let st = try await e.status()
                online = true; adfLoaded = st.adfLoaded
                let feeder: Bool
                switch source {
                case .auto: feeder = st.adfLoaded
                case .platen: feeder = false
                case .feeder: feeder = true
                }
                if feeder && !st.adfLoaded {
                    throw AppError("自动进纸器中没有纸张。请放入纸张，或将「来源」改为「平板」。")
                }
                let (d, pw, ph) = await e.adjust(feeder: feeder, dpi: dpi, width: paper.size.0, height: paper.size.1)
                let before = pages.count
                statusText = feeder ? "正在从自动进纸器扫描…" : "正在扫描第 \(before + 1) 页…"
                let n = try await e.scan(feeder: feeder, gray: color != .color, dpi: d, width: pw, height: ph) { data in
                    await MainActor.run {
                        self.addPage(data, dpi: d)
                        if feeder { self.statusText = "正在从自动进纸器扫描…已接收 \(self.pages.count - before) 页" }
                    }
                }
                var msg = "本次扫描 \(n) 页，共 \(pages.count) 页"
                if d != dpi { msg += "（该扫描仪的\(feeder ? "自动进纸器" : "平板")不支持 \(dpi) dpi，已改用 \(d) dpi）" }
                statusText = msg
            } catch {
                statusText = "扫描失败"
                alert = Self.friendly(error)
            }
            isScanning = false
        }
    }

    nonisolated static func friendly(_ error: Error) -> String {
        if let e = error as? AppError { return e.message }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "无法连接扫描仪。请确认打印机已开机并与本机连接同一网络，或点击左侧「自动查找扫描仪」。\n（详细信息：\(ns.localizedDescription)）"
        }
        return error.localizedDescription
    }

    func addPage(_ data: Data, dpi: Int) {
        guard let img = ImageOps.decode(data) else { alert = "无法解码扫描结果。"; return }
        let p = ScanPage(raw: img, dpi: dpi)
        pages.append(p)
        enqueue(p.id)
    }

    // 处理队列：一页一页处理，避免高分辨率时内存暴涨
    func reprocessAll() { for p in pages { enqueue(p.id) } }

    func enqueue(_ id: UUID) {
        if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].processing = true }
        if !queue.contains(id) { queue.append(id) }
        if !working { Task { await runQueue() } }
    }

    private func runQueue() async {
        working = true
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let idx = pages.firstIndex(where: { $0.id == id }) else { continue }
            let raw = pages[idx].raw, d = pages[idx].dpi, s = settings
            let orient = autoRotate && !pages[idx].oriented
            let (out, small, rot) = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGImage, Int) in
                let o = ImageOps.process(raw, dpi: d, s: s)
                return (o, ImageOps.scaled(o, maxSide: 700), orient ? ImageOps.detectRotation(o) : 0)
            }.value
            guard let i = pages.firstIndex(where: { $0.id == id }) else { continue }
            if orient && !pages[i].oriented {
                pages[i].oriented = true
                pages[i].rotation = rot
            }
            pages[i].processed = out
            pages[i].small = small
            pages[i].thumb = NSImage(cgImage: ImageOps.rotate(small, pages[i].rotation), size: .zero)
            pages[i].processing = queue.contains(id)
        }
        working = false
    }

    func waitProcessing() async {
        while working || pages.contains(where: { $0.processed == nil }) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // 页面操作
    func rotate(_ id: UUID, _ by: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].rotation = ((pages[i].rotation + by) % 360 + 360) % 360
        if let s = pages[i].small { pages[i].thumb = NSImage(cgImage: ImageOps.rotate(s, pages[i].rotation), size: .zero) }
    }

    func move(_ id: UUID, _ by: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        let j = i + by
        guard j >= 0 && j < pages.count else { return }
        pages.swapAt(i, j)
    }

    func delete(_ id: UUID) {
        pages.removeAll { $0.id == id }
        queue.removeAll { $0 == id }
    }

    func clearAll() {
        pages.removeAll()
        queue.removeAll()
        statusText = "已清空全部页面"
    }

    // 输出
    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.directoryURL = outputURL
        p.prompt = "选择"
        p.message = "选择扫描文件的保存位置"
        if p.runModal() == .OK, let u = p.url { outputDir = u.path }
    }

    static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "扫描_" + f.string(from: Date())
    }

    func cleanName() -> String {
        var n = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".pdf", ".PDF", ".jpg", ".JPG"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
        n = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return n.isEmpty ? Self.defaultName() : n
    }

    private func items() -> [Exporter.Item] {
        pages.compactMap { p in p.processed.map { Exporter.Item(image: $0, dpi: p.dpi, rotation: p.rotation) } }
    }

    func save() {
        guard !pages.isEmpty, !busy else { return }
        isSaving = true
        statusText = "正在保存…"
        Task {
            await waitProcessing()
            let its = items(), q = quality.jpeg, fmt = format, dir = outputURL, name = cleanName()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let urls = try await Task.detached(priority: .userInitiated) {
                    try Exporter.export(its, format: fmt, quality: q, dir: dir, name: name)
                }.value
                statusText = "已保存：\(urls[0].lastPathComponent)" + (urls.count > 1 ? " 等 \(urls.count) 个文件" : "")
                if revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                if clearAfterSave { pages.removeAll() }
                fileName = ""
            } catch {
                statusText = "保存失败"
                alert = "保存失败：\(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    func chooseInsertTarget() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = false
        p.directoryURL = outputURL
        p.prompt = "选择"
        p.message = "选择要插入扫描页面的 PDF 文件"
        guard p.runModal() == .OK, let u = p.url else { return }
        guard let doc = PDFDocument(url: u) else { alert = "无法打开所选 PDF 文件。"; return }
        appendPageCount = doc.pageCount
        appendAfter = doc.pageCount
        appendTarget = u
    }

    func doInsert() {
        guard let target = appendTarget, !busy else { return }
        appendTarget = nil
        isSaving = true
        statusText = "正在将页面插入 \(target.lastPathComponent)…"
        Task {
            await waitProcessing()
            let its = items(), q = quality.jpeg, after = appendAfter
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Exporter.insert(its, quality: q, into: target, after: after)
                }.value
                statusText = "已将 \(its.count) 页插入 \(target.lastPathComponent)，原文件已移至废纸篓"
                if revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                if clearAfterSave { pages.removeAll() }
            } catch {
                statusText = "插入失败"
                alert = "插入失败：\(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

// MARK: - 界面

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @State private var confirmClear = false

    struct PreviewItem: Identifiable { let id: UUID }

    var body: some View {
        HStack(spacing: 0) {
            SettingsPanel()
                .frame(width: 340)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(m.pages.isEmpty ? "暂无扫描页面" : "已扫描 \(m.pages.count) 页")
                        .font(.headline)
                    if m.pages.contains(where: { $0.processing }) {
                        ProgressView().controlSize(.small)
                        Text("处理中…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !m.pages.isEmpty {
                        Text("点击页面可放大预览").foregroundStyle(.secondary).font(.callout)
                        Button(role: .destructive) { confirmClear = true } label: { Label("清空全部", systemImage: "trash") }
                            .disabled(m.busy)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                PagesArea()
                Divider()
                BottomBar()
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .confirmationDialog("确定清空全部已扫描页面？", isPresented: $confirmClear) {
            Button("清空 \(m.pages.count) 页", role: .destructive) { m.clearAll() }
        } message: { Text("未保存的页面将无法恢复。") }
        .sheet(item: Binding(get: { m.previewID.map { PreviewItem(id: $0) } }, set: { m.previewID = $0?.id })) { item in
            PreviewSheet(currentID: item.id).environmentObject(m)
        }
        .sheet(isPresented: Binding(get: { m.appendTarget != nil }, set: { if !$0 { m.appendTarget = nil } })) {
            InsertSheet().environmentObject(m)
        }
        .alert("提示", isPresented: Binding(get: { m.alert != nil }, set: { if !$0 { m.alert = nil } })) {
            Button("确定") { m.alert = nil }
        } message: { Text(m.alert ?? "") }
    }
}

struct SettingsPanel: View {
    @EnvironmentObject var m: AppModel

    var statusLabel: (String, Color) {
        if m.host.trimmingCharacters(in: .whitespaces).isEmpty { return (m.searching ? "正在查找…" : "未设置", .gray) }
        guard let on = m.online else { return ("正在检测…", .gray) }
        if !on { return ("无法连接", .red) }
        switch m.scannerState {
        case "Idle": return ("在线 · 空闲", .green)
        case "Processing": return ("在线 · 忙碌（正在扫描或打印）", .orange)
        case "Testing": return ("在线 · 自检中", .orange)
        case "Stopped": return ("在线 · 已停止（请检查打印机面板）", .red)
        default: return ("在线", .green)
        }
    }

    var body: some View {
        Form {
            Section("扫描仪") {
                TextField("地址", text: $m.host, prompt: Text("打印机 IP 地址，例如 192.168.1.20"))
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle().fill(statusLabel.1).frame(width: 9, height: 9)
                        Text(statusLabel.0)
                    }
                }
                LabeledContent("自动进纸器") { Text(m.adfLoaded ? "已放入纸张" : "无纸张") }
                HStack {
                    Button(m.searching ? "正在查找…" : "自动查找扫描仪") { m.discover() }
                        .disabled(m.searching)
                    if m.searching { ProgressView().controlSize(.small) }
                }
                ForEach(m.found) { f in
                    Button { m.host = f.id } label: {
                        HStack {
                            Image(systemName: m.host == f.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(m.host == f.id ? Color.accentColor : Color.secondary)
                            Text("\(f.model)  ·  \(f.id)")
                                .foregroundStyle(Color.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                Picker("来源", selection: $m.source) {
                    ForEach(SourceChoice.allCases) { Text($0.label).tag($0) }
                }
                Picker("颜色", selection: $m.color) {
                    ForEach(ColorChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("分辨率", selection: $m.dpi) {
                    Text("75 dpi · 预览").tag(75)
                    Text("200 dpi · 较小文件").tag(200)
                    Text("300 dpi · 推荐").tag(300)
                    Text("600 dpi · 高精度（仅平板）").tag(600)
                }
                Picker("纸张", selection: $m.paper) {
                    ForEach(PaperChoice.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("扫描")
            } footer: {
                Text("来源为「自动选择」时：自动进纸器中有纸张则从进纸器扫描（可连续扫描多页），否则从平板扫描。自动进纸器最高支持 300 dpi。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("背景", selection: $m.bg) {
                    ForEach(BgChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("自动裁除四周空白（适用于护照、证件、票据）", isOn: $m.autoCrop)
                Toggle("去除污点和灰尘", isOn: $m.despeckle)
                    .disabled(m.bg != .document && m.color != .bw)
                Toggle("自动校正方向（依据文字方向）", isOn: $m.autoRotate)
            } header: {
                Text("图像处理")
            } footer: {
                Text("文字与表格请选择「文档」；护照、证件和照片请选择「证件与照片」，以保留彩色底纹。修改设置后，已扫描的页面将自动重新处理。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("输出") {
                LabeledContent("保存位置") {
                    Text((m.outputDir as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("选择文件夹…") { m.chooseFolder() }
                    Button("在访达中打开") { NSWorkspace.shared.open(m.outputURL) }
                }
                Picker("文件质量", selection: $m.quality) {
                    ForEach(QualityChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("保存后在访达中显示", isOn: $m.revealAfterSave)
                Toggle("保存后清空已扫描页面", isOn: $m.clearAfterSave)
            }
        }
        .formStyle(.grouped)
    }
}

struct PagesArea: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        if m.pages.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text("将文件放在平板上或放入自动进纸器，然后点击「扫描」")
                    .font(.title3)
                Text("支持连续扫描多页，并合并保存为一个 PDF 文件。\n快捷键：⌘↩ 扫描　⌘S 保存")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                    ForEach(Array(m.pages.enumerated()), id: \.element.id) { i, p in
                        PageCard(page: p, index: i, count: m.pages.count)
                    }
                }
                .padding(16)
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let tip: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 20) }
            .buttonStyle(.borderless)
            .help(tip)
    }
}

struct PageCard: View {
    @EnvironmentObject var m: AppModel
    let page: ScanPage
    let index: Int
    let count: Int

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10))
                if let t = page.thumb {
                    Image(nsImage: t)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(8)
                }
                if page.processing {
                    ProgressView().controlSize(.small)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(height: 250)
            .contentShape(Rectangle())
            .onTapGesture { m.previewID = page.id }
            Text("第 \(index + 1) 页").font(.callout)
            HStack(spacing: 4) {
                IconButton(symbol: "arrow.left", tip: "前移") { m.move(page.id, -1) }.disabled(index == 0)
                IconButton(symbol: "rotate.left", tip: "向左旋转 90°") { m.rotate(page.id, -90) }
                IconButton(symbol: "rotate.right", tip: "向右旋转 90°") { m.rotate(page.id, 90) }
                IconButton(symbol: "trash", tip: "删除此页") { m.delete(page.id) }
                IconButton(symbol: "arrow.right", tip: "后移") { m.move(page.id, 1) }.disabled(index == count - 1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

struct BottomBar: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button { m.scan() } label: {
                Label(m.isScanning ? "扫描中…" : "扫描", systemImage: "scanner")
                    .frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(m.busy)
            if m.busy { ProgressView().controlSize(.small) }
            Text(m.statusText)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("文件名（留空则按时间命名）", text: $m.fileName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Picker("", selection: $m.format) {
                ForEach(FormatChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100)
            .help("PDF：所有页面合并为一个文件；JPG：每页保存为一张图片")
            Button("插入到现有 PDF…") { m.chooseInsertTarget() }
                .fixedSize()
                .disabled(m.pages.isEmpty || m.busy)
                .help("将已扫描的页面插入现有 PDF 文件的指定位置")
            Button { m.save() } label: {
                Label("保存", systemImage: "square.and.arrow.down").frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(m.pages.isEmpty || m.busy)
        }
        .padding(12)
    }
}

struct PreviewSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var currentID: UUID
    @State private var big: NSImage?

    var index: Int? { m.pages.firstIndex { $0.id == currentID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let i = index {
                    Text("第 \(i + 1) / \(m.pages.count) 页").font(.headline)
                }
                Spacer()
                IconButton(symbol: "chevron.left", tip: "上一页") { step(-1) }.disabled((index ?? 0) == 0)
                IconButton(symbol: "chevron.right", tip: "下一页") { step(1) }.disabled((index ?? 0) >= m.pages.count - 1)
                Divider().frame(height: 18)
                IconButton(symbol: "rotate.left", tip: "向左旋转 90°") { m.rotate(currentID, -90) }
                IconButton(symbol: "rotate.right", tip: "向右旋转 90°") { m.rotate(currentID, 90) }
                IconButton(symbol: "trash", tip: "删除此页") { deleteCurrent() }
                Divider().frame(height: 18)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let b = big {
                    Image(nsImage: b).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(16)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 820, idealHeight: 960)
        .task(id: renderKey) { await render() }
    }

    var renderKey: String {
        guard let i = index else { return "none" }
        let p = m.pages[i]
        return "\(p.id)-\(p.rotation)-\(p.processed.map { "\($0.width)x\($0.height)-\(ObjectIdentifier($0).hashValue)" } ?? "nil")"
    }

    func render() async {
        guard let i = index, let img = m.pages[i].processed else { big = nil; return }
        let rot = m.pages[i].rotation
        let out = await Task.detached(priority: .userInitiated) {
            ImageOps.rotate(ImageOps.scaled(img, maxSide: 2000), rot)
        }.value
        big = NSImage(cgImage: out, size: .zero)
    }

    func step(_ d: Int) {
        guard let i = index else { return }
        let j = i + d
        guard j >= 0 && j < m.pages.count else { return }
        big = nil
        currentID = m.pages[j].id
    }

    func deleteCurrent() {
        guard let i = index else { return }
        let next: UUID? = i + 1 < m.pages.count ? m.pages[i + 1].id : (i > 0 ? m.pages[i - 1].id : nil)
        m.delete(currentID)
        if let n = next { big = nil; currentID = n } else { dismiss() }
    }
}

struct InsertSheet: View {
    @EnvironmentObject var m: AppModel

    var placeText: String {
        let c = m.appendPageCount
        if m.appendAfter == 0 { return "插入到第 1 页之前" }
        if m.appendAfter >= c { return "插入到末尾（第 \(c) 页之后）" }
        return "插入到第 \(m.appendAfter) 页之后"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("插入到现有 PDF").font(.title3.bold())
            if let t = m.appendTarget {
                Label("\(t.lastPathComponent)（共 \(m.appendPageCount) 页）", systemImage: "doc.richtext")
            }
            Stepper(value: $m.appendAfter, in: 0...max(0, m.appendPageCount)) {
                Text(placeText).frame(minWidth: 220, alignment: .leading)
            }
            Text("将插入 \(m.pages.count) 页（按当前的旋转、背景和裁切设置）。原文件会先移至废纸篓备份，再写入新版本，文件名保持不变。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { m.appendTarget = nil }.keyboardShortcut(.cancelAction)
                Button("插入") { m.doInsert() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

// MARK: - App 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // 调试用：SCAN_TEST_IMAGES=图1,图2 预先放入页面；SCAN_SNAPSHOT=输出.png 几秒后把窗口截图并退出
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let list = env["SCAN_TEST_IMAGES"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for path in list.split(separator: ",") {
                    if let d = try? Data(contentsOf: URL(fileURLWithPath: String(path))) { AppModel.shared?.addPage(d, dpi: 300) }
                }
            }
        }
        if let out = env["SCAN_SNAPSHOT"] {
            let delay = Double(env["SCAN_SNAPSHOT_DELAY"] ?? "6") ?? 6
            var oldFrame: NSRect?
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, delay - 2)) {
                NSApp.activate(ignoringOtherApps: true)
                guard let w = NSApp.windows.first(where: { $0.isVisible }) else { return }
                w.makeKeyAndOrderFront(nil)
                // SCAN_SNAPSHOT_SIZE=宽x高：截图时临时调整窗口大小，截完恢复
                if let sz = env["SCAN_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), sz.count == 2 {
                    oldFrame = w.frame
                    w.setContentSize(NSSize(width: sz[0], height: sz[1]))
                    w.center()
                }
                w.makeFirstResponder(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let w = NSApp.windows.first(where: { $0.isVisible }), let content = w.contentView else { exit(3) }
                defer { if let f = oldFrame { w.setFrame(f, display: false) } }
                // 优先用窗口服务器截取本窗口（应用截取自己的窗口无需屏幕录制权限）
                if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution]), cg.width > 10 {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    if let f = oldFrame { w.setFrame(f, display: false) }
                    exit(0)
                }
                // 退回：含标题栏的整个窗口（frame view）
                let v = content.superview ?? content
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(3) }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
        }
    }
}

struct ScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("雷霆扫描") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.startPolling() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - 命令行（测试用）

enum CLI {
    static func opts(_ args: [String]) -> [String: String] {
        var d: [String: String] = [:]
        for a in args where a.contains("=") {
            let p = a.split(separator: "=", maxSplits: 1).map(String.init)
            d[p[0]] = p[1]
        }
        return d
    }

    static func settings(_ o: [String: String]) -> ProcSettings {
        let bg: BgChoice = o["bg"] == "off" ? .off : (o["bg"] == "light" ? .light : .document)
        let color: ColorChoice = o["color"] == "gray" ? .gray : (o["color"] == "bw" ? .bw : .color)
        return ProcSettings(bg: bg, color: color, autoCrop: o["crop"] == "1", despeckle: o["speck"] != "0")
    }

    static func runSync(_ body: @escaping () async throws -> Void) -> Int32 {
        final class Box: @unchecked Sendable { var code: Int32 = 0 }
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached {
            do { try await body() } catch {
                FileHandle.standardError.write((AppModel.friendly(error) + "\n").data(using: .utf8)!)
                box.code = 1
            }
            sem.signal()
        }
        sem.wait()
        return box.code
    }

    static func run(_ args: [String]) -> Int32 {
        let o = opts(args)
        let pos = args.filter { !$0.contains("=") }
        switch pos.first {
        case "--discover":
            return runSync {
                for f in await ESCL.discover() { print(f.id, f.model) }
            }
        case "--process":
            guard pos.count >= 3 else { print("用法：--process 输入 输出.pdf [选项]"); return 2 }
            let inURL = URL(fileURLWithPath: pos[1]), outURL = URL(fileURLWithPath: pos[2])
            let dpi = Int(o["dpi"] ?? "300") ?? 300
            let img: CGImage?
            if inURL.pathExtension.lowercased() == "pdf" {
                img = ImageOps.renderPDF(inURL, page: Int(o["page"] ?? "0") ?? 0, dpi: dpi)
            } else {
                img = (try? Data(contentsOf: inURL)).flatMap(ImageOps.decode)
            }
            guard let src = img else { print("无法读取输入文件"); return 1 }
            let t = Date()
            let out = ImageOps.process(src, dpi: dpi, s: settings(o))
            let rot = o["rot"] == "auto" ? ImageOps.detectRotation(out) : (Int(o["rot"] ?? "0") ?? 0)
            print(String(format: "处理 %dx%d -> %dx%d 旋转 %d° 用时 %.2fs", src.width, src.height, out.width, out.height, rot, Date().timeIntervalSince(t)))
            do {
                try Exporter.writePDF([.init(image: out, dpi: dpi, rotation: rot)], quality: 0.8, to: outURL)
            } catch { print(error.localizedDescription); return 1 }
            return 0
        case "--scan":
            guard pos.count >= 2 else { print("用法：--scan 输出.pdf [选项]"); return 2 }
            let outURL = URL(fileURLWithPath: pos[1])
            return runSync {
                var host = o["host"] ?? ""
                if host.isEmpty {
                    guard let f = await ESCL.discover().first else { throw AppError("未找到扫描仪，请使用 host=IP 指定") }
                    host = f.id
                    print("使用扫描仪 \(f.model)（\(f.id)）")
                }
                let e = ESCL(host: host)
                let st = try await e.status()
                let feeder = o["src"] == "feeder" || (o["src"] ?? "auto" == "auto" && st.adfLoaded)
                let paper: PaperChoice = o["paper"] == "letter" ? .letter : (o["paper"] == "full" ? .full : .a4)
                let (dpi, pw, ph) = await e.adjust(feeder: feeder, dpi: Int(o["dpi"] ?? "300") ?? 300, width: paper.size.0, height: paper.size.1)
                print("来源 \(feeder ? "自动进纸器" : "平板")  \(dpi) dpi  区域 \(pw)x\(ph)")
                let s = settings(o)
                var items: [Exporter.Item] = []
                let raws = o["raw"]
                let n = try await e.scan(feeder: feeder, gray: s.color != .color, dpi: dpi, width: pw, height: ph) { data in
                    if let r = raws { try? data.write(to: URL(fileURLWithPath: r + "_\(items.count + 1).jpg")) }
                    guard let img = ImageOps.decode(data) else { return }
                    let t = Date()
                    let out = ImageOps.process(img, dpi: dpi, s: s)
                    let rot = o["rot"] == "auto" ? ImageOps.detectRotation(out) : (Int(o["rot"] ?? "0") ?? 0)
                    print(String(format: "第 %d 页 %dx%d -> %dx%d 旋转 %d° 处理 %.2fs", items.count + 1, img.width, img.height, out.width, out.height, rot, Date().timeIntervalSince(t)))
                    items.append(.init(image: out, dpi: dpi, rotation: rot))
                }
                try Exporter.writePDF(items, quality: 0.8, to: outURL)
                print("扫描 \(n) 页 -> \(outURL.path)")
            }
        case "--insert", "--export-jpg":
            // --insert 目标.pdf 图1.jpg 图2.jpg after=N   /   --export-jpg 文件夹 名字 图1.jpg 图2.jpg
            let isInsert = pos[0] == "--insert"
            let files = Array(pos.dropFirst(isInsert ? 2 : 3))
            let items = files.compactMap { f -> Exporter.Item? in
                guard let d = try? Data(contentsOf: URL(fileURLWithPath: f)), let img = ImageOps.decode(d) else { return nil }
                return Exporter.Item(image: img, dpi: 300, rotation: 0)
            }
            do {
                if isInsert {
                    try Exporter.insert(items, quality: 0.8, into: URL(fileURLWithPath: pos[1]), after: Int(o["after"] ?? "9999") ?? 9999)
                    print("插入 \(items.count) 页 -> \(pos[1])")
                } else {
                    let urls = try Exporter.export(items, format: .jpg, quality: 0.8, dir: URL(fileURLWithPath: pos[1]), name: pos[2])
                    print(urls.map { $0.lastPathComponent }.joined(separator: " "))
                }
            } catch { print(error.localizedDescription); return 1 }
            return 0
        default:
            print("未知参数。可用命令：--discover、--scan、--process、--insert、--export-jpg")
            return 2
        }
    }
}

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let a = args.first, a.hasPrefix("--") {
            exit(CLI.run(args))
        }
        ScanApp.main()
    }
}
