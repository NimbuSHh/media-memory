// 生成 Media Memory 的应用图标：羊毛毡拍立得。
// 用法：xcrun swift make-app-icon.swift <输出目录>
// 在 <输出目录>/AppIcon.iconset 产出 Apple iconset 全部尺寸的 PNG（供 iconutil 打包），
// 在 <输出目录> 产出 1024px 母版 AppIcon-1024.png。
// 日常通过同目录 build-icon.sh 再生成，勿手工编辑 PNG。
//
// 造型语义：一张缝在毛毡手帐上的拍立得——"给记忆拍张照，随时找回那几秒"。
// 配色三族：燕麦毡（相纸/线/播放键/爱心）、珊瑚毡（相片/爱心）、各自暗部（厚度层）。
// 质感配方：轮廓绒毛晕 + 内部纤维斑点 + 2.5D 厚度层 + 手工跑针缝线。
// 图形全部矢量绘制、按画布比例参数化；同目录 build-icon.sh 一键再生成。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : ".")

// MARK: - 画布常量（Big Sur 模板：1024 画布，824 圆角矩形，投影烘进画布）

let canvas: CGFloat = 1024
let tileOrigin: CGFloat = 100
let tileSize: CGFloat = 824
let tileCornerRadius: CGFloat = 185

// MARK: - 三色族

let oat = CGColor(srgbRed: 0.953, green: 0.914, blue: 0.843, alpha: 1)        // 燕麦毡 #F3E9D7
let oatDeep = CGColor(srgbRed: 0.851, green: 0.784, blue: 0.663, alpha: 1)    // 燕麦暗部
let oatLight = CGColor(srgbRed: 0.996, green: 0.976, blue: 0.925, alpha: 1)   // 相纸白
let coralFelt = CGColor(srgbRed: 0.941, green: 0.541, blue: 0.447, alpha: 1)  // 珊瑚毡 #F08A72
let coralDeep = CGColor(srgbRed: 0.816, green: 0.404, blue: 0.302, alpha: 1)  // 珊瑚暗部
let feltShadow = CGColor(srgbRed: 0.38, green: 0.30, blue: 0.22, alpha: 0.22)

func tilePath() -> CGPath {
    CGPath(roundedRect: CGRect(x: tileOrigin, y: tileOrigin, width: tileSize, height: tileSize),
           cornerWidth: tileCornerRadius, cornerHeight: tileCornerRadius, transform: nil)
}

// MARK: - 可复现伪随机（同一种子同一形状，迭代微调不跳变）

struct LCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
    mutating func phase() -> Double { next() * 6.28318 }
}

// MARK: - 手绘几何

func wobblyPolygon(_ points: [CGPoint], amp: CGFloat, seed: UInt64) -> CGPath {
    var rng = LCG(seed)
    let p1 = rng.phase(), p2 = rng.phase()
    let path = CGMutablePath()
    let steps = 16
    for (e, start) in points.enumerated() {
        let end = points[(e + 1) % points.count]
        let dx = end.x - start.x, dy = end.y - start.y
        let nx = -dy / hypot(dx, dy), ny = dx / hypot(dx, dy)
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let wobble = amp * sin(t * 4.4 + p1 + CGFloat(e) * 1.9)
                + amp * 0.45 * sin(t * 10.3 + p2)
            let pt = CGPoint(x: start.x + dx * t + nx * wobble,
                             y: start.y + dy * t + ny * wobble)
            if e == 0 && i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
    }
    path.closeSubpath()
    return path
}

// 圆角胖三角播放键：角二次曲线圆润化，边低幅抖动——形要正，手感靠毛边。
func chubbyPlay(center: CGPoint, width: CGFloat, height: CGFloat,
                corner: CGFloat, amp: CGFloat, seed: UInt64) -> CGPath {
    var rng = LCG(seed)
    let p1 = rng.phase()
    let nudge = width * 0.08
    let corners = [
        CGPoint(x: center.x - width / 2 + nudge, y: center.y + height / 2),
        CGPoint(x: center.x - width / 2 + nudge, y: center.y - height / 2),
        CGPoint(x: center.x + width / 2 + nudge, y: center.y),
    ]
    let path = CGMutablePath()
    let steps = 12
    for e in 0..<3 {
        let start = corners[e], end = corners[(e + 1) % 3]
        let dx = end.x - start.x, dy = end.y - start.y
        let len = hypot(dx, dy)
        let ux = dx / len, uy = dy / len
        let sx = start.x + ux * corner, sy = start.y + uy * corner
        let ex = end.x - ux * corner, ey = end.y - uy * corner
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let wobble = amp * sin(t * 3.4 + p1 + CGFloat(e) * 2.1)
            let pt = CGPoint(x: sx + (ex - sx) * t - uy * wobble,
                             y: sy + (ey - sy) * t + ux * wobble)
            if e == 0 && i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        let next = corners[(e + 1) % 3]
        let ndx = corners[(e + 2) % 3].x - next.x, ndy = corners[(e + 2) % 3].y - next.y
        let nlen = hypot(ndx, ndy)
        path.addQuadCurve(to: CGPoint(x: next.x + ndx / nlen * corner,
                                      y: next.y + ndy / nlen * corner),
                          control: next)
    }
    path.closeSubpath()
    return path
}

func heartPath(center: CGPoint, width: CGFloat, angle: CGFloat) -> CGPath {
    let w = width, h = width * 0.92
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y - h / 2))
    path.addQuadCurve(to: CGPoint(x: center.x - w * 0.30, y: center.y + h * 0.22),
                      control: CGPoint(x: center.x - w * 0.60, y: center.y - h * 0.02))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + h * 0.06),
                      control: CGPoint(x: center.x - w * 0.16, y: center.y + h * 0.40))
    path.addQuadCurve(to: CGPoint(x: center.x + w * 0.30, y: center.y + h * 0.22),
                      control: CGPoint(x: center.x + w * 0.16, y: center.y + h * 0.40))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - h / 2),
                      control: CGPoint(x: center.x + w * 0.60, y: center.y - h * 0.02))
    path.closeSubpath()
    guard angle != 0 else { return path }
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: angle).translatedBy(x: -center.x, y: -center.y)
    return path.copy(using: &transform)!
}

// MARK: - 毛毡质感

func collectPoints(of path: CGPath) -> [CGPoint] {
    var points: [CGPoint] = []
    path.applyWithBlock { element in
        switch element.pointee.type {
        case .moveToPoint, .addLineToPoint:
            points.append(element.pointee.points[0])
        case .addQuadCurveToPoint:
            // 二次曲线手工展平：缝线和绒毛需要密集顶点。
            let c = element.pointee.points[0], end = element.pointee.points[1]
            if let last = points.last {
                let start = last
                for i in 1...12 {
                    let t = CGFloat(i) / 12
                    let mt = 1 - t
                    points.append(CGPoint(x: mt * mt * start.x + 2 * mt * t * c.x + t * t * end.x,
                                          y: mt * mt * start.y + 2 * mt * t * c.y + t * t * end.y))
                }
            }
        default: break
        }
    }
    return points
}

// 轮廓绒毛：沿边向外挑出短纤维，羊毛毡的核心质感。
func feltFuzz(context: CGContext, path: CGPath, color: CGColor,
              seed: UInt64, step: CGFloat = 8, outLength: CGFloat = 14) {
    let points = collectPoints(of: path)
    guard points.count > 2 else { return }
    var centroid = CGPoint.zero
    for p in points { centroid = CGPoint(x: centroid.x + p.x / CGFloat(points.count),
                                         y: centroid.y + p.y / CGFloat(points.count)) }
    var rng = LCG(seed)
    context.setStrokeColor(color)
    context.setLineWidth(2.2)
    context.setLineCap(.round)
    for i in 0..<points.count {
        let a = points[i], b = points[(i + 1) % points.count]
        let segLen = hypot(b.x - a.x, b.y - a.y)
        guard segLen > 0.5 else { continue }
        let fibers = max(1, Int(segLen / step))
        for j in 0..<fibers {
            let t = (CGFloat(j) + rng.next()) / CGFloat(fibers)
            let base = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            var angle = atan2(b.y - a.y, b.x - a.x) + (rng.next() - 0.5) * 1.4
            let nx = cos(angle), ny = sin(angle)
            let outward = (base.x - centroid.x) * nx + (base.y - centroid.y) * ny
            if outward < 0 { angle += .pi }
            let len = 5 + rng.next() * outLength
            context.move(to: CGPoint(x: base.x - cos(angle) * 2, y: base.y - sin(angle) * 2))
            context.addLine(to: CGPoint(x: base.x + cos(angle) * len,
                                        y: base.y + sin(angle) * len))
            context.strokePath()
        }
    }
}

// 内部纤维斑点：毡化的杂色纤维。
func feltMottle(context: CGContext, path: CGPath, bounds: CGRect,
                deep: CGColor, light: CGColor, seed: UInt64) {
    var rng = LCG(seed)
    for _ in 0..<1500 {
        let x = bounds.minX + rng.next() * bounds.width
        let y = bounds.minY + rng.next() * bounds.height
        guard path.contains(CGPoint(x: x, y: y), using: .winding) else { continue }
        let r = 1.4 + rng.next() * 2.2
        context.setFillColor(rng.next() > 0.62 ? light : deep)
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}

// 手工跑针：沿任意闭合路径走针，针距与离缝随机，像真手缝。
func runningStitch(context: CGContext, along path: CGPath, seed: UInt64, color: CGColor,
                   width: CGFloat, stitch: CGFloat = 30, gap: CGFloat = 26,
                   jitter: CGFloat = 5) {
    let points = collectPoints(of: path)
    guard points.count > 2 else { return }
    var rng = LCG(seed)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    var traveled: CGFloat = rng.next() * 18
    var onStitch = true
    for i in 0..<points.count {
        let a = points[i], b = points[(i + 1) % points.count]
        let segLen = hypot(b.x - a.x, b.y - a.y)
        guard segLen > 0.5 else { continue }
        let ux = (b.x - a.x) / segLen, uy = (b.y - a.y) / segLen
        var t: CGFloat = 0
        while t < segLen {
            let remain = onStitch ? stitch * (0.75 + rng.next() * 0.5)
                                  : gap * (0.75 + rng.next() * 0.5)
            let run = min(remain, segLen - t)
            if onStitch {
                let off = (rng.next() - 0.5) * 2 * jitter
                context.move(to: CGPoint(x: a.x + ux * t - uy * off, y: a.y + uy * t + ux * off))
                context.addLine(to: CGPoint(x: a.x + ux * (t + run) - uy * off,
                                            y: a.y + uy * (t + run) + ux * off))
                context.strokePath()
            }
            t += run
            traveled += run
            if traveled >= (onStitch ? stitch : gap) {
                traveled = 0
                onStitch.toggle()
            }
        }
    }
}

// MARK: - 底：燕麦毛毡

func drawFeltTile(context: CGContext) {
    context.setShadow(offset: CGSize(width: 0, height: -20), blur: 32,
                      color: CGColor(srgbRed: 0.30, green: 0.24, blue: 0.17, alpha: 0.30))
    context.addPath(tilePath())
    context.clip()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    context.setFillColor(oat)
    context.fill(CGRect(x: tileOrigin, y: tileOrigin, width: tileSize, height: tileSize))

    // 毡面：短纤维丝，深浅两色随机走向。
    var rng = LCG(7102026)
    let fiberDeep = CGColor(srgbRed: 0.76, green: 0.68, blue: 0.54, alpha: 0.60)
    let fiberLight = CGColor(srgbRed: 1.0, green: 0.99, blue: 0.95, alpha: 0.65)
    for i in 0..<4600 {
        let x = tileOrigin + 8 + rng.next() * (tileSize - 16)
        let y = tileOrigin + 8 + rng.next() * (tileSize - 16)
        let angle = rng.phase()
        let len = 3 + rng.next() * 5
        context.setStrokeColor(i % 2 == 0 ? fiberDeep : fiberLight)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + CGFloat(cos(angle)) * len,
                                    y: y + CGFloat(sin(angle)) * len))
        context.setLineWidth(1.2 + rng.next() * 0.9)
        context.strokePath()
    }
}

// 毛毡片通用绘制：厚度层 + 本体 + 纤维斑点 + 绒毛。
func drawFeltPiece(context: CGContext, path: CGPath, underPath: CGPath,
                   face: CGColor, under: CGColor,
                   mottleBounds: CGRect, seed: UInt64,
                   faceDeep: CGColor, faceLight: CGColor,
                   shadow: CGFloat = 14, fuzzStep: CGFloat = 8, fuzzOut: CGFloat = 14) {
    context.setShadow(offset: CGSize(width: 0, height: -shadow), blur: 24, color: feltShadow)
    context.setFillColor(under)
    context.addPath(underPath)
    context.fillPath()
    context.setFillColor(face)
    context.addPath(path)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    feltMottle(context: context, path: path, bounds: mottleBounds,
               deep: faceDeep, light: faceLight, seed: seed &+ 5)
    feltFuzz(context: context, path: path,
             color: face.copy(alpha: 0.75) ?? face, seed: seed &+ 9,
             step: fuzzStep, outLength: fuzzOut)
}

// MARK: - 羊毛毡拍立得

func drawFeltPolaroid(context: CGContext) {
    drawFeltTile(context: context)

    context.saveGState()
    context.translateBy(x: 512, y: 505)
    context.rotate(by: -5 * .pi / 180)
    context.translateBy(x: -512, y: -505)

    // 相纸：厚度层 + 本体。
    drawFeltPiece(
        context: context,
        path: wobblyPolygon([CGPoint(x: 262, y: 800), CGPoint(x: 762, y: 800),
                             CGPoint(x: 762, y: 210), CGPoint(x: 262, y: 210)],
                            amp: 3.2, seed: 15),
        underPath: wobblyPolygon([CGPoint(x: 262, y: 788), CGPoint(x: 762, y: 788),
                                  CGPoint(x: 762, y: 198), CGPoint(x: 262, y: 198)],
                                 amp: 3.2, seed: 16),
        face: oatLight, under: oatDeep,
        mottleBounds: CGRect(x: 250, y: 190, width: 524, height: 624),
        seed: 100, faceDeep: CGColor(srgbRed: 0.88, green: 0.83, blue: 0.72, alpha: 0.35),
        faceLight: CGColor(srgbRed: 1.0, green: 0.995, blue: 0.97, alpha: 0.5),
        shadow: 18)

    // 相片：珊瑚毡窗口，上缘一道暗边表现"嵌进相纸"的凹槽。
    let photo = wobblyPolygon([CGPoint(x: 306, y: 756), CGPoint(x: 718, y: 756),
                               CGPoint(x: 718, y: 360), CGPoint(x: 306, y: 360)],
                              amp: 3.0, seed: 25)
    context.setFillColor(coralFelt)
    context.addPath(photo)
    context.fillPath()
    feltMottle(context: context, path: photo,
               bounds: CGRect(x: 300, y: 354, width: 424, height: 408),
               deep: CGColor(srgbRed: 0.78, green: 0.36, blue: 0.26, alpha: 0.20),
               light: CGColor(srgbRed: 1.0, green: 0.72, blue: 0.62, alpha: 0.22),
               seed: 130)
    feltFuzz(context: context, path: photo,
             color: coralFelt.copy(alpha: 0.6) ?? coralFelt, seed: 26, step: 9, outLength: 10)
    context.setFillColor(coralDeep.copy(alpha: 0.45) ?? coralDeep)
    context.fill(CGRect(x: 308, y: 741, width: 408, height: 15))

    // 相片缝线：奶油线把相片缝在相纸上。
    runningStitch(context: context,
                  along: wobblyPolygon([CGPoint(x: 322, y: 740), CGPoint(x: 702, y: 740),
                                        CGPoint(x: 702, y: 376), CGPoint(x: 322, y: 376)],
                                       amp: 2.6, seed: 27),
                  seed: 140, color: oatLight, width: 8.5, stitch: 26, gap: 24, jitter: 4)

    // 播放键：独立奶油毡片，缝在相片中央。
    let play = chubbyPlay(center: CGPoint(x: 512, y: 560), width: 196,
                          height: 214, corner: 52, amp: 2.6, seed: 45)
    drawFeltPiece(
        context: context,
        path: play,
        underPath: chubbyPlay(center: CGPoint(x: 512, y: 553), width: 196,
                              height: 214, corner: 52, amp: 2.6, seed: 45),
        face: oatLight, under: CGColor(srgbRed: 0.88, green: 0.82, blue: 0.70, alpha: 1),
        mottleBounds: CGRect(x: 400, y: 440, width: 224, height: 240),
        seed: 150, faceDeep: CGColor(srgbRed: 0.88, green: 0.83, blue: 0.72, alpha: 0.4),
        faceLight: CGColor(srgbRed: 1.0, green: 1.0, blue: 0.98, alpha: 0.55),
        shadow: 9, fuzzStep: 7, fuzzOut: 9)
    runningStitch(context: context,
                  along: chubbyPlay(center: CGPoint(x: 512, y: 560), width: 158,
                                    height: 172, corner: 40, amp: 2.2, seed: 46),
                  seed: 160, color: coralDeep, width: 5.5, stitch: 17, gap: 15, jitter: 3)

    // 相纸外圈跑针：珊瑚线固定整张拍立得。
    runningStitch(context: context,
                  along: wobblyPolygon([CGPoint(x: 292, y: 770), CGPoint(x: 732, y: 770),
                                        CGPoint(x: 732, y: 240), CGPoint(x: 292, y: 240)],
                                       amp: 3.0, seed: 28),
                  seed: 170, color: coralFelt, width: 9.5, stitch: 30, gap: 27, jitter: 5)

    context.restoreGState()

    // 右下：珊瑚毡小爱心贴布，奶油线勾边。
    let heart = heartPath(center: CGPoint(x: 786, y: 246), width: 100, angle: 12 * .pi / 180)
    drawFeltPiece(
        context: context,
        path: heart,
        underPath: heartPath(center: CGPoint(x: 786, y: 240), width: 100, angle: 12 * .pi / 180),
        face: coralFelt, under: coralDeep,
        mottleBounds: CGRect(x: 726, y: 186, width: 120, height: 120),
        seed: 180, faceDeep: CGColor(srgbRed: 0.78, green: 0.36, blue: 0.26, alpha: 0.25),
        faceLight: CGColor(srgbRed: 1.0, green: 0.75, blue: 0.65, alpha: 0.28),
        shadow: 8, fuzzStep: 7, fuzzOut: 9)
    runningStitch(context: context,
                  along: heartPath(center: CGPoint(x: 786, y: 246), width: 72,
                                   angle: 12 * .pi / 180),
                  seed: 190, color: oatLight, width: 5.5, stitch: 15, gap: 13, jitter: 3)
}

// MARK: - 渲染与输出

func renderPNG(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(width) / canvas
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    drawFeltPolaroid(context: context)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                      UTType.png.identifier as CFString,
                                                      1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// iconset 全尺寸逐档矢量直出（非母版缩放），小尺寸边缘更干净。
// 尺寸与文件名是 iconutil 的硬性约定，改动后 icns 会缺档；
// 目录名必须以 .iconset 结尾，否则 iconutil 拒绝打包。
let iconsetSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
let iconsetDirectory = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconsetDirectory,
                                         withIntermediateDirectories: true)
for entry in iconsetSizes {
    writePNG(renderPNG(width: entry.pixels, height: entry.pixels),
             to: iconsetDirectory.appendingPathComponent(entry.name))
}

writePNG(renderPNG(width: 1024, height: 1024),
         to: outputDirectory.appendingPathComponent("AppIcon-1024.png"))

print("已生成 iconset 与母版到 \(outputDirectory.path)")
