// ============================================================
//  make-icon.swift - 从一张白底的方形 PNG Logo 生成：
//    * macOS 的 AppIcon.iconset（各档位 PNG，交给 iconutil 打 .icns）
//    * Windows 的 picker.ico（安装包 / 快捷方式 / exe 图标）
//    * README 用的透明底展示图
//
//  用法（通常由 make-icon.sh 调用，不直接跑）：
//    make-icon <logo.png> <out-assets-dir> <out-docs-dir> <out-iconset-dir>
//
//  处理流水线：
//    1. 按「离白色的最大通道距离」找图形外框（阈值 60），裁掉四周白边
//    2. 从裁切边界洪水填充出背景（离白 <= 20 且与边界连通）
//    3. 贴边像素按覆盖率取 alpha，并按 alpha 反混合，去掉白底残留的浅色描边
//    4. 图形体缩放到 824x824：顺带把原图轻微的纵向压扁校正回正方
//    5. 居中放进 1024x1024 透明画布（Apple macOS 图标网格：体 824 / 画布 1024）
//    6. 逐级减半导出各档位，避免一次性大比例缩放带来的锯齿
// ============================================================
import Foundation
import CoreGraphics
import ImageIO

// MARK: - 可调参数

/// 距白超过该值才算「图形」（抗锯齿过渡带被排除在外）
let bboxThreshold = 60
/// 距白不超过该值且与画布边界连通，才算「背景」
let bgTolerance = 20
/// 距白达到该值即视为像素被图形完全覆盖
let fullCoverageD: Float = 200
/// 边缘内缩比例：抵消反混合的估计误差，去掉最后一丝浅色描边
let edgeErosion: Float = 0.25
/// macOS 图标画布与图形体（Apple 官方网格）
let iconCanvas = 1024
let iconBody = 824
/// Windows .ico 的档位；>= 128 用 PNG 压缩，更小的用 32bpp DIB（兼容性最好）
let icoSizes = [16, 24, 32, 48, 64, 128, 256]
let icoPNGThreshold = 128
/// README 展示图边长
let docSize = 512

// MARK: - 位图容器：RGBA8，预乘 alpha，第 0 行是图像顶行

struct Bitmap {
    let width: Int
    let height: Int
    var px: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.px = [UInt8](repeating: 0, count: width * height * 4)
    }

    init(width: Int, height: Int, px: [UInt8]) {
        self.width = width
        self.height = height
        self.px = px
    }

    func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    /// 离白色的最大通道距离，0 = 纯白
    func distanceFromWhite(_ x: Int, _ y: Int) -> Int {
        let i = offset(x, y)
        return max(255 - Int(px[i]), 255 - Int(px[i + 1]), 255 - Int(px[i + 2]))
    }
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("无法创建 \(w)x\(h) 绘图上下文")
    }
    // 注意：这里**不要**加 translate/scale 翻转。
    // CGBitmapContext 的缓冲第 0 行就是图像顶行，CGImage 直接 draw 进去方向已经正确；
    // 多加一次翻转会让除 1024 档（恰好被翻转两次抵消）以外的所有档位上下颠倒。
    ctx.interpolationQuality = .high
    return ctx
}

func readBack(_ ctx: CGContext, _ w: Int, _ h: Int) -> Bitmap {
    guard let data = ctx.data else { fatalError("绘图上下文没有像素缓冲") }
    let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    return Bitmap(width: w, height: h,
                  px: Array(UnsafeBufferPointer(start: buf, count: w * h * 4)))
}

func bitmapToImage(_ bm: Bitmap) -> CGImage {
    guard let provider = CGDataProvider(data: Data(bm.px) as CFData),
          let img = CGImage(width: bm.width, height: bm.height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: bm.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true,
                            intent: .defaultIntent) else {
        fatalError("无法构造 \(bm.width)x\(bm.height) CGImage")
    }
    return img
}

func imageToBitmap(_ img: CGImage) -> Bitmap {
    let w = img.width, h = img.height
    let ctx = makeContext(w, h)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return readBack(ctx, w, h)
}

func resize(_ bm: Bitmap, to w: Int, _ h: Int) -> Bitmap {
    let ctx = makeContext(w, h)
    ctx.draw(bitmapToImage(bm), in: CGRect(x: 0, y: 0, width: w, height: h))
    return readBack(ctx, w, h)
}

// MARK: - 步骤 1：定位图形外框

func artworkBounds(_ bm: Bitmap, threshold: Int) -> (x: Int, y: Int, w: Int, h: Int) {
    var x0 = bm.width, y0 = bm.height, x1 = -1, y1 = -1
    for y in 0..<bm.height {
        for x in 0..<bm.width where bm.distanceFromWhite(x, y) > threshold {
            if x < x0 { x0 = x }
            if x > x1 { x1 = x }
            if y < y0 { y0 = y }
            if y > y1 { y1 = y }
        }
    }
    guard x1 >= x0, y1 >= y0 else { fatalError("图里找不到任何非白像素，确认输入是不是白底 Logo") }
    return (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
}

func crop(_ bm: Bitmap, x: Int, y: Int, w: Int, h: Int) -> Bitmap {
    var out = Bitmap(width: w, height: h)
    for row in 0..<h {
        let src = bm.offset(x, y + row)
        let dst = out.offset(0, row)
        out.px.replaceSubrange(dst..<(dst + w * 4), with: bm.px[src..<(src + w * 4)])
    }
    return out
}

// MARK: - 步骤 2/3：抠背景 + 边缘反混合

/// 返回带透明通道的图形体。像素为预乘 alpha，可直接缩放。
func cutout(_ bm: Bitmap) -> Bitmap {
    let w = bm.width, h = bm.height, n = w * h

    // 背景判定：离白够近
    var isBG = [Bool](repeating: false, count: n)
    for y in 0..<h {
        for x in 0..<w where bm.distanceFromWhite(x, y) <= bgTolerance {
            isBG[y * w + x] = true
        }
    }

    // 从四边洪水填充，只有与边界连通的浅色才是真背景；
    // 图形内部的白色（显示器外框、手机机身）因此不会被误挖成透明。
    var reachable = [Bool](repeating: false, count: n)
    var stack: [Int] = []
    stack.reserveCapacity(n / 4)
    for x in 0..<w {
        let top = x, bottom = (h - 1) * w + x
        if isBG[top], !reachable[top] { reachable[top] = true; stack.append(top) }
        if isBG[bottom], !reachable[bottom] { reachable[bottom] = true; stack.append(bottom) }
    }
    for y in 0..<h {
        let left = y * w, right = y * w + w - 1
        if isBG[left], !reachable[left] { reachable[left] = true; stack.append(left) }
        if isBG[right], !reachable[right] { reachable[right] = true; stack.append(right) }
    }
    while let idx = stack.popLast() {
        let x = idx % w, y = idx / w
        if x > 0     { let k = idx - 1; if isBG[k], !reachable[k] { reachable[k] = true; stack.append(k) } }
        if x < w - 1 { let k = idx + 1; if isBG[k], !reachable[k] { reachable[k] = true; stack.append(k) } }
        if y > 0     { let k = idx - w; if isBG[k], !reachable[k] { reachable[k] = true; stack.append(k) } }
        if y < h - 1 { let k = idx + w; if isBG[k], !reachable[k] { reachable[k] = true; stack.append(k) } }
    }

    // 覆盖率：背景 0，内部 1，贴边像素按离白距离估算
    var coverage = [Float](repeating: 1, count: n)
    var out = bm
    for y in 0..<h {
        for x in 0..<w {
            let idx = y * w + x
            if reachable[idx] { coverage[idx] = 0; continue }

            let touchesBG = (x == 0 || y == 0 || x == w - 1 || y == h - 1)
                || reachable[idx - 1] || reachable[idx + 1]
                || reachable[idx - w] || reachable[idx + w]
            guard touchesBG else { continue }

            let d = Float(out.distanceFromWhite(x, y))
            let alpha = min(1, max(0, d / fullCoverageD))
            coverage[idx] = alpha

            // 观测值 C = alpha*F + (1-alpha)*白  =>  真实色 F = (C - (1-alpha)*255) / alpha
            // 不这么做，圆角外沿会留一圈发白的描边（在深色背景上尤其明显）
            if alpha >= 0.15 {
                let base = out.offset(x, y)
                for k in 0..<3 {
                    let c = Float(out.px[base + k])
                    let f = (c - (1 - alpha) * 255) / alpha
                    out.px[base + k] = UInt8(min(255, max(0, f.rounded())))
                }
            }
        }
    }

    // 转成预乘 alpha
    for idx in 0..<n {
        let a = coverage[idx]
        let base = idx * 4
        if a <= 0 {
            out.px[base] = 0; out.px[base + 1] = 0; out.px[base + 2] = 0; out.px[base + 3] = 0
        } else {
            for k in 0..<3 { out.px[base + k] = UInt8(min(255, (Float(out.px[base + k]) * a).rounded())) }
            out.px[base + 3] = UInt8((a * 255).rounded())
        }
    }
    return out
}

/// 边缘内缩：把 alpha 曲线整体推紧一点，抵消覆盖率的估计误差
func erodeEdges(_ bm: Bitmap, by amount: Float) -> Bitmap {
    guard amount > 0 else { return bm }
    var out = bm
    for idx in 0..<(bm.width * bm.height) {
        let base = idx * 4
        let a = Float(out.px[base + 3]) / 255
        guard a > 0 else { continue }
        let shrunk = min(1, max(0, (a - amount) / (1 - amount)))
        if shrunk <= 0 {
            out.px[base] = 0; out.px[base + 1] = 0; out.px[base + 2] = 0; out.px[base + 3] = 0
        } else if shrunk != a {
            // 预乘像素：先还原成直色，乘上新 alpha 再预乘回去
            for k in 0..<3 {
                let straight = Float(out.px[base + k]) / a
                out.px[base + k] = UInt8(min(255, max(0, (straight * shrunk).rounded())))
            }
            out.px[base + 3] = UInt8((shrunk * 255).rounded())
        }
    }
    return out
}

/// 居中放进透明画布
func pad(_ bm: Bitmap, to side: Int) -> Bitmap {
    var out = Bitmap(width: side, height: side)
    let ox = (side - bm.width) / 2, oy = (side - bm.height) / 2
    for y in 0..<bm.height {
        let src = bm.offset(0, y)
        let dst = out.offset(ox, oy + y)
        out.px.replaceSubrange(dst..<(dst + bm.width * 4), with: bm.px[src..<(src + bm.width * 4)])
    }
    return out
}

// MARK: - 档位导出（逐级减半，避免大比例一次缩放的锯齿）

func derive(_ master: Bitmap, side: Int) -> Bitmap {
    if side == master.width { return master }
    var cur = master
    var size = master.width
    while size / 2 >= side {
        cur = resize(cur, to: size / 2, size / 2)
        size /= 2
    }
    if size == side { return cur }
    return resize(cur, to: side, side)
}

// MARK: - 编码

func pngData(_ bm: Bitmap) -> Data {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
        fatalError("无法创建 PNG 编码器")
    }
    CGImageDestinationAddImage(dest, bitmapToImage(bm), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 编码失败") }
    return out as Data
}

func writePNG(_ bm: Bitmap, to path: String) {
    try! pngData(bm).write(to: URL(fileURLWithPath: path))
}

/// 图形体内「上亮下暗」的均值对，用来判断方向
func toneBands(_ bm: Bitmap) -> (top: Float, bottom: Float)? {
    let body = Int((Double(bm.width) * Double(iconBody) / Double(iconCanvas)).rounded())
    let off = (bm.width - body) / 2
    guard body >= 8 else { return nil }
    var top: Float = 0, bottom: Float = 0
    var nt = 0, nb = 0
    for y in off..<(off + body) {
        for x in off..<(off + body) {
            let i = bm.offset(x, y)
            guard bm.px[i + 3] > 200 else { continue }
            if y < off + body / 5 { top += Float(bm.px[i + 1]); nt += 1 }
            else if y > off + body - body / 5 { bottom += Float(bm.px[i + 1]); nb += 1 }
        }
    }
    guard nt > 0, nb > 0 else { return nil }
    return (top / Float(nt), bottom / Float(nb))
}

/// 方向自检：每一档的明暗走向必须与主图一致。
/// （开发时踩过一次：给绘图上下文多加了一层翻转，1024 档因两次翻转抵消而正常，
///  其余档位全部上下颠倒，且肉眼只在小尺寸上才看得出来 —— 所以这里直接断死。）
func assertOrientation(_ derived: Bitmap, reference: Bitmap, label: String) {
    guard let ref = toneBands(reference), let got = toneBands(derived) else { return }
    guard abs(ref.top - ref.bottom) > 8 else { return }   // 上下本来就没差异，跳过
    if (got.top > got.bottom) != (ref.top > ref.bottom) {
        print("ERROR: \(label) 的方向与主图相反（缩放阶段把图翻过来了）")
        exit(1)
    }
}

/// 写文件前统一过一遍方向自检
func emit(_ bm: Bitmap, to path: String, label: String, reference: Bitmap) {
    assertOrientation(bm, reference: reference, label: label)
    writePNG(bm, to: path)
}

func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func u32(_ v: Int) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

/// ICO 内嵌的 DIB：BITMAPINFOHEADER + 自下而上的 BGRA + AND 掩码
func dibPayload(_ bm: Bitmap) -> Data {
    let w = bm.width, h = bm.height
    var d = Data()
    d.append(contentsOf: u32(40))          // biSize
    d.append(contentsOf: u32(w))           // biWidth
    d.append(contentsOf: u32(h * 2))       // biHeight：ICO 约定为「颜色 + 掩码」两倍高
    d.append(contentsOf: u16(1))           // biPlanes
    d.append(contentsOf: u16(32))          // biBitCount
    d.append(contentsOf: u32(0))           // biCompression = BI_RGB
    d.append(contentsOf: u32(w * h * 4))   // biSizeImage
    d.append(contentsOf: u32(0))           // biXPelsPerMeter
    d.append(contentsOf: u32(0))           // biYPelsPerMeter
    d.append(contentsOf: u32(0))           // biClrUsed
    d.append(contentsOf: u32(0))           // biClrImportant
    for y in stride(from: h - 1, through: 0, by: -1) {
        for x in 0..<w {
            let i = bm.offset(x, y)
            d.append(bm.px[i + 2])         // B
            d.append(bm.px[i + 1])         // G
            d.append(bm.px[i])             // R
            d.append(bm.px[i + 3])         // A
        }
    }
    d.append(Data(count: ((w + 31) / 32) * 4 * h))   // AND 掩码：32bpp 下全 0
    return d
}

func writeICO(_ images: [Bitmap], to path: String, reference: Bitmap) {
    var payloads: [(side: Int, data: Data)] = []
    for bm in images {
        assertOrientation(bm, reference: reference, label: "picker.ico \(bm.width)px")
        payloads.append((bm.width, bm.width >= icoPNGThreshold ? pngData(bm) : dibPayload(bm)))
    }
    let headerSize = 6 + 16 * payloads.count
    var offset = headerSize
    var out = Data()
    out.append(contentsOf: u16(0))            // reserved
    out.append(contentsOf: u16(1))            // type = icon
    out.append(contentsOf: u16(payloads.count))
    for item in payloads {
        let dim = item.side >= 256 ? 0 : item.side    // 256 在 ICO 里用 0 表示
        out.append(UInt8(dim))
        out.append(UInt8(dim))
        out.append(0)                         // 调色板数
        out.append(0)                         // reserved
        out.append(contentsOf: u16(1))        // planes
        out.append(contentsOf: u16(32))       // 位深
        out.append(contentsOf: u32(item.data.count))
        out.append(contentsOf: u32(offset))
        offset += item.data.count
    }
    for item in payloads { out.append(item.data) }
    try! out.write(to: URL(fileURLWithPath: path))
}

// MARK: - 主流程

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("用法: make-icon <logo.png> <out-assets-dir> <out-docs-dir> <out-iconset-dir>")
    exit(2)
}
let inputPath = args[1]
let assetsDir = args[2]
let docsDir = args[3]
let iconsetDir = args[4]
let fm = FileManager.default

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("ERROR: 读不到输入图 \(inputPath)")
    exit(1)
}

let src = imageToBitmap(sourceImage)
let box = artworkBounds(src, threshold: bboxThreshold)
print("==> 输入 \(src.width)x\(src.height)，图形外框 x=\(box.x) y=\(box.y) \(box.w)x\(box.h)"
      + String(format: "（纵横比 %.4f）", Double(box.h) / Double(box.w)))

let body = erodeEdges(cutout(crop(src, x: box.x, y: box.y, w: box.w, h: box.h)),
                      by: edgeErosion)
let square = resize(body, to: iconBody, iconBody)
let master = pad(square, to: iconCanvas)

// AppIcon.iconset：iconutil 要求这 10 个文件名齐全
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
let slots: [(name: String, side: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for slot in slots {
    emit(derive(master, side: slot.side), to: iconsetDir + "/" + slot.name,
         label: slot.name, reference: master)
}
print("==> iconset: \(slots.count) 个档位 -> \(iconsetDir)（方向自检通过）")

try! fm.createDirectory(atPath: docsDir, withIntermediateDirectories: true)
let docPath = docsDir + "/app-icon.png"
emit(derive(master, side: docSize), to: docPath, label: "app-icon.png", reference: master)
print("==> 文档展示图: \(docPath)（\(docSize)px，透明底）")

try! fm.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)
let icoPath = assetsDir + "/picker.ico"
writeICO(icoSizes.map { derive(master, side: $0) }, to: icoPath, reference: master)
print("==> Windows 图标: \(icoPath)（档位 \(icoSizes.map(String.init).joined(separator: "/"))）")
