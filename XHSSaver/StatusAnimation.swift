import SwiftUI

/// 下载页顶上的状态动画：全部是纯色的平面图形，用 Canvas 实时画，不带任何素材。
/// 三层：背景的大色块和点阵；16 个小图形在三条轨道上绕着中心转；中间的圆和两圈细环。
/// 每个状态有自己的动作（见 StatusAnimationModel.render），切换时各个图形快慢不同地过渡过去。
/// 只是装饰：不接受点按，辅助功能里看不到（状态由 `phase` 标识给出）
struct StatusAnimation: View {
    enum Kind: Int, CaseIterable {
        case idle, parsing, waiting, downloading, saving, finished, failed
    }

    let kind: Kind
    /// 下载 / 保存的进度（0…1）；算不出来时是 nil
    let progress: Double?
    /// 不在眼前（别的标签页、退到后台）时停下，不白耗电
    var paused = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = StatusAnimationModel()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused || reduceMotion)) { line in
            Canvas { g, size in
                model.render(g, size: size, dark: scheme == .dark, date: line.date, kind: kind, progress: progress)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 动画的全部状态和画法。是引用类型：每一帧在 Canvas 里直接改，不经过 SwiftUI 的状态更新
final class StatusAnimationModel {
    private typealias Kind = StatusAnimation.Kind

    private struct RGB {
        var r: Double, g: Double, b: Double
        func mix(_ o: RGB, _ t: Double) -> RGB {
            RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
        }
        func color(_ alpha: Double) -> Color {
            Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: min(1, max(0, alpha)))
        }
    }

    private struct Palette {
        let violet: RGB, rose: RGB, lav: RGB, peach: RGB, fg: RGB, bg: RGB, amber: RGB, green: RGB
        static let light = Palette(violet: RGB(r: 106, g: 61, b: 240), rose: RGB(r: 255, g: 94, b: 126),
                                   lav: RGB(r: 185, g: 165, b: 255), peach: RGB(r: 255, g: 177, b: 153),
                                   fg: RGB(r: 28, g: 27, b: 34), bg: RGB(r: 242, g: 241, b: 247),
                                   amber: RGB(r: 245, g: 165, b: 36), green: RGB(r: 31, g: 174, b: 122))
        static let dark = Palette(violet: RGB(r: 138, g: 102, b: 255), rose: RGB(r: 255, g: 111, b: 140),
                                  lav: RGB(r: 168, g: 146, b: 255), peach: RGB(r: 255, g: 169, b: 143),
                                  fg: RGB(r: 241, g: 240, b: 246), bg: RGB(r: 15, g: 14, b: 20),
                                  amber: RGB(r: 255, g: 184, b: 77), green: RGB(r: 53, g: 201, b: 144))
        func element(_ i: Int) -> RGB {
            switch i {
            case 0: return violet
            case 1: return rose
            case 2: return lav
            case 3: return peach
            default: return fg
            }
        }
    }

    /// 一个小图形
    private struct Element {
        let index: Int
        /// 0 圆 1 方 2 三角 3 圆环 4 半圆 5 加号 6 胶囊
        let type: Int
        let color: Int
        let size: Double
        /// 在第几条轨道上
        let ring: Int
        /// 每个图形自己的一个 0…1 的数：决定它过渡得快还是慢、下载时什么时候进场
        let k: Double
        let spin: Double
        var angle: Double
        var x = 0.0, y = 0.0, rot = 0.0, scale = 1.0, alpha = 1.0
        var lastP = 0.0
        var placed = false
        /// 画在中间的圆后面
        var behind = false
    }

    private static let count = 16
    private static let ringSpeed: [Double] = [0.28, -0.2, 0.14]
    private static let ringX: [Double] = [72, 108, 142]
    private static let ringY: [Double] = [30, 48, 64]
    /// 各状态下：转速、轨道大小
    private static let speeds: [Double] = [1, 3.4, 0.15, 1.8, 0, 0.7, 0]
    private static let radii: [Double] = [1, 0.7, 1.06, 1, 1, 1.16, 1]

    private var els: [Element]
    /// 每个状态现在占多少（0…1），切换时一个升一个降
    private var amt = [Double](repeating: 0, count: Kind.allCases.count)
    /// 外面要的状态，和现在画的状态（完成 / 失败停几秒后自己回到空闲）
    private var requested = Kind.idle
    private var shown = Kind.idle
    private var since = 0.0
    private var last = 0.0
    private var t = 0.0
    private var speed = 1.0
    private var radius = 1.0
    private var ringAngle = 0.0
    private var pop = 0.0
    private var shake = 0.0
    private var prog = 0.0
    private var ripples: [Double] = []

    init() {
        let sizes: [Double] = [7, 10, 8, 12, 9]
        var list: [Element] = []
        for i in 0..<Self.count {
            let d = Double(i)
            let spin = (i % 2 == 1 ? 1.0 : -1.0) * (0.4 + (d * 0.37).truncatingRemainder(dividingBy: 1))
            let angle = d / Double(Self.count) * 6.283 * 3 + (d * 1.7).truncatingRemainder(dividingBy: 1)
            list.append(Element(index: i, type: i % 8 == 7 ? 0 : i % 8, color: (i * 3) % 5, size: sizes[i % 5], ring: i % 3,
                                k: (d * 0.618).truncatingRemainder(dividingBy: 1), spin: spin, angle: angle))
        }
        els = list
        amt[Kind.idle.rawValue] = 1
    }

    private func ease(_ v: Double, _ to: Double, _ dt: Double, _ k: Double) -> Double {
        v + (to - v) * (1 - exp(-dt * k))
    }

    private func enter(_ k: Kind) {
        guard k != shown else { return }
        shown = k
        since = t
        pop = 1
        ripples.append(0)
        if k == .failed { shake = 1 }
    }

    private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private func arc(_ x: Double, _ y: Double, _ r: Double, _ from: Double, _ to: Double) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
        return p
    }

    private func stroke(_ width: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    func render(_ g: GraphicsContext, size: CGSize, dark: Bool, date: Date, kind: StatusAnimation.Kind, progress: Double?) {
        let now = date.timeIntervalSinceReferenceDate
        let dt = last == 0 ? 0 : min(0.05, max(0, now - last))
        last = now
        t += dt

        if kind != requested {
            requested = kind
            enter(kind)
        }
        // 完成、失败停 6 秒就回到空闲的样子，不一直挂着
        if (shown == .finished || shown == .failed) && t - since > 6 { enter(.idle) }

        for k in Kind.allCases {
            amt[k.rawValue] = ease(amt[k.rawValue], k == shown ? 1 : 0, dt, 6)
        }
        speed = ease(speed, Self.speeds[shown.rawValue], dt, 3)
        radius = ease(radius, Self.radii[shown.rawValue], dt, 4)
        pop = ease(pop, 0, dt, 5)
        shake = ease(shake, 0, dt, 4)
        ringAngle += dt * speed * 0.8
        if shown == .downloading || shown == .saving {
            prog = ease(prog, progress ?? 0, dt, 6)
        } else {
            prog = 0
        }

        let pal = dark ? Palette.dark : Palette.light
        let w = Double(size.width), h = Double(size.height)
        let cx = w / 2 + sin(t * 38) * 5 * shake
        let cy = h / 2
        let sx = min(1.25, (w / 2 - 12) / (142 * 1.16))
        let cell = min(30, (w - 24) / 8)

        drawBackground(g, pal, w, h)
        updateElements(dt, w, h, cx, cy, sx, cell, known: progress != nil)
        for e in els where e.behind { drawElement(g, e, pal, cell) }
        drawHub(g, pal, cx, cy, dt, known: progress != nil)
        for e in els where !e.behind { drawElement(g, e, pal, cell) }
    }

    // 第一层：大色块、点阵、斜线
    private func drawBackground(_ g: GraphicsContext, _ pal: Palette, _ w: Double, _ h: Double) {
        let drift = sin(t * 0.25) * 6
        g.fill(circle(w * 0.17 + drift, h * 0.36, 54 + speed * 2), with: .color(pal.violet.color(0.07)))
        let a0 = ringAngle * 0.3
        g.stroke(arc(w * 0.86 - drift, h * 0.72, 42, a0, a0 + 4.2), with: .color(pal.rose.color(0.09)),
                 style: StrokeStyle(lineWidth: 14))
        let pill = CGRect(x: w * 0.30 + drift * 0.5, y: h * 0.78, width: 46, height: 12)
        g.fill(Path(roundedRect: pill, cornerRadius: 6), with: .color(pal.peach.color(0.16)))
        // 点阵：解析时有一条亮带从右往左扫
        let parsing = amt[Kind.parsing.rawValue]
        for c in 0..<6 {
            let scan = max(0, sin(Double(c) * 0.9 - t * 5)) * parsing
            let color = pal.fg.mix(pal.violet, scan).color(0.16 + 0.5 * scan)
            for r in 0..<4 {
                g.fill(circle(w * 0.66 + Double(c) * 9, h * 0.1 + Double(r) * 9, 1.4 + scan * 0.8), with: .color(color))
            }
        }
        let slide = (ringAngle * 6).truncatingRemainder(dividingBy: 8)
        var lines = Path()
        for l in 0..<5 {
            let lx = w * 0.06 + Double(l) * 8 + slide
            lines.move(to: CGPoint(x: lx, y: h * 0.9))
            lines.addLine(to: CGPoint(x: lx + 10, y: h * 0.78))
        }
        g.stroke(lines, with: .color(pal.fg.color(0.1)), style: StrokeStyle(lineWidth: 2))
    }

    // 第二层：算每个小图形该去哪，再让它带着自己的快慢靠过去
    private func updateElements(_ dt: Double, _ w: Double, _ h: Double, _ cx: Double, _ cy: Double,
                                _ sx: Double, _ cell: Double, known: Bool) {
        let n = Self.count
        let orbit = shown != .downloading && shown != .saving && shown != .failed
        let lit = Int((prog * Double(n)).rounded())
        for i in els.indices {
            var e = els[i]
            e.angle += dt * speed * Self.ringSpeed[e.ring]
            let depth = sin(e.angle)
            let rx = Self.ringX[e.ring] * sx
            let ry = Self.ringY[e.ring]
            var tx = 0.0, ty = 0.0, tScale = 1.0, tAlpha = 1.0
            var tRot = e.rot + dt * e.spin * (0.4 + speed * 0.5)
            var k = 3 + e.k * 5

            switch shown {
            case .downloading:
                // 从外圈旋进中心，到了就从外圈重新来
                let p = (t * 0.38 + e.k).truncatingRemainder(dividingBy: 1)
                let rad = pow(1 - p, 1.4) * 1.2
                let a = e.angle + p * 2.2
                tx = cx + cos(a) * rx * rad
                ty = cy + sin(a) * ry * rad
                tScale = 1 - 0.65 * p
                tAlpha = min(1, p * 8) * min(1, (1 - p) * 5)
                k = 14
                if p < e.lastP {
                    e.x = tx
                    e.y = ty
                    e.alpha = 0
                }
                e.lastP = p
            case .saving:
                // 排成两排方格；进度到哪亮到哪，不知道进度就一格格轮着亮
                tx = cx + (Double(e.index % 8) - 3.5) * cell
                ty = cy + (Double(e.index / 8) - 0.5) * cell
                tScale = 0.78
                tRot = 0
                if known {
                    tAlpha = e.index < lit ? 1 : 0.3
                } else {
                    tAlpha = 0.3 + 0.7 * max(0, sin(t * 3 - Double(e.index) * 0.5))
                }
            case .failed:
                // 掉到底边
                tx = w * (0.08 + 0.84 * Double((e.index * 7) % n) / Double(n - 1))
                ty = h - 13 - Double(e.index % 3) * 3
                tScale = 0.9
                tAlpha = 0.6
                tRot = e.spin * 2
                k = 5 + e.k * 6
            default:
                tx = cx + cos(e.angle) * rx * radius
                ty = cy + sin(e.angle) * ry * radius
                tScale = 0.82 + 0.24 * depth
            }

            if !e.placed {
                e.x = tx
                e.y = ty
                e.placed = true
            }
            e.x = ease(e.x, tx, dt, k)
            e.y = ease(e.y, ty, dt, k)
            e.scale = ease(e.scale, tScale, dt, k)
            e.alpha = ease(e.alpha, tAlpha, dt, 8)
            e.rot = ease(e.rot, tRot, dt, 8)
            e.behind = shown == .downloading || (orbit && depth < 0)
            els[i] = e
        }
    }

    private func drawElement(_ g: GraphicsContext, _ e: Element, _ pal: Palette, _ cell: Double) {
        let grey = pal.fg.mix(pal.bg, 0.55)
        let rgb = pal.element(e.color).mix(grey, amt[Kind.failed.rawValue] * 0.8)
        let saving = amt[Kind.saving.rawValue]
        var c = g
        c.translateBy(x: e.x, y: e.y)
        if saving > 0.02 {
            // 保存时每个图形底下垫一块浅色方格，像相册里的缩略图
            let tile = CGRect(x: -cell * 0.4, y: -cell * 0.4, width: cell * 0.8, height: cell * 0.8)
            c.fill(Path(roundedRect: tile, cornerRadius: 6), with: .color(rgb.color(saving * 0.16 * (e.alpha > 0.6 ? 1 : 0.5))))
        }
        c.rotate(by: .radians(e.rot))
        c.scaleBy(x: e.scale, y: e.scale)
        let s = e.size
        let shading = GraphicsContext.Shading.color(rgb.color(e.alpha))
        switch e.type {
        case 0:
            c.fill(circle(0, 0, s / 2), with: shading)
        case 1:
            c.fill(Path(roundedRect: CGRect(x: -s / 2, y: -s / 2, width: s, height: s), cornerRadius: s * 0.22), with: shading)
        case 2:
            var p = Path()
            p.move(to: CGPoint(x: -s * 0.4, y: -s * 0.5))
            p.addLine(to: CGPoint(x: s * 0.55, y: 0))
            p.addLine(to: CGPoint(x: -s * 0.4, y: s * 0.5))
            p.closeSubpath()
            c.fill(p, with: shading)
        case 3:
            c.stroke(circle(0, 0, s * 0.42), with: shading, style: StrokeStyle(lineWidth: s * 0.26))
        case 4:
            var p = arc(0, 0, s * 0.55, 0, Double.pi)
            p.closeSubpath()
            c.fill(p, with: shading)
        case 5:
            let bar = s * 0.28
            var p = Path()
            p.addRect(CGRect(x: -s / 2, y: -bar / 2, width: s, height: bar))
            p.addRect(CGRect(x: -bar / 2, y: -s / 2, width: bar, height: s))
            c.fill(p, with: shading)
        default:
            let r = CGRect(x: -s * 0.65, y: -s * 0.28, width: s * 1.3, height: s * 0.56)
            c.fill(Path(roundedRect: r, cornerRadius: s * 0.28), with: shading)
        }
    }

    // 第三层：中间的圆、两圈细环、进度、圆里的记号
    private func drawHub(_ g: GraphicsContext, _ pal: Palette, _ cx: Double, _ cy: Double, _ dt: Double, known: Bool) {
        let idle = amt[Kind.idle.rawValue], parsing = amt[Kind.parsing.rawValue], waiting = amt[Kind.waiting.rawValue]
        let downloading = amt[Kind.downloading.rawValue], saving = amt[Kind.saving.rawValue]
        let finished = amt[Kind.finished.rawValue], failed = amt[Kind.failed.rawValue]
        let hubColor = pal.violet.mix(pal.green, finished).mix(pal.rose, failed)

        // 换状态时从圆上荡出去的一圈
        ripples = ripples.map { $0 + dt }.filter { $0 < 0.9 }
        for age in ripples {
            g.stroke(circle(cx, cy, 24 + age * 110), with: .color(hubColor.color((1 - age / 0.9) * 0.45)),
                     style: StrokeStyle(lineWidth: 2))
        }

        // 保存时圆收起来，把中间让给方格
        let hub = (1 - saving) * (1 + pop * 0.16 + sin(t * 3) * 0.035 * waiting)
        guard hub > 0.03 else { return }
        let r0 = 24 * hub

        let ringColor = hubColor.color(0.45 * (1 - downloading) * hub)
        for i in 0..<3 {
            let a = ringAngle + Double(i) * 2.094
            g.stroke(arc(cx, cy, 34 * hub, a, a + 1.25), with: .color(ringColor), style: StrokeStyle(lineWidth: 2))
        }
        for d in 0..<12 {
            let a = -ringAngle * 0.6 + Double(d) * 0.5236
            g.fill(circle(cx + cos(a) * 42 * hub, cy + sin(a) * 42 * hub, 1.3), with: .color(pal.fg.color(0.22 * hub)))
        }
        if downloading > 0.02 {
            g.stroke(circle(cx, cy, 34), with: .color(hubColor.color(0.16 * downloading)), style: StrokeStyle(lineWidth: 4))
            let top = -Double.pi / 2
            // 知道进度就画进度，不知道就画一段转着的弧
            let bar = known ? arc(cx, cy, 34, top, top + 6.283 * max(0.01, prog)) : arc(cx, cy, 34, t * 4, t * 4 + 1.6)
            g.stroke(bar, with: .color(pal.rose.color(downloading)), style: stroke(4))
        }
        if waiting > 0.02 {
            let a = t * 0.8
            g.fill(circle(cx + cos(a) * 34, cy + sin(a) * 34, 4), with: .color(pal.amber.color(waiting * (0.6 + 0.4 * sin(t * 4)))))
        }
        g.fill(circle(cx, cy, r0), with: .color(hubColor.color(1)))

        var c = g
        c.clip(to: circle(cx, cy, r0))
        c.translateBy(x: cx, y: cy)
        c.scaleBy(x: hub, y: hub)
        let pen = stroke(3)
        func ink(_ a: Double) -> GraphicsContext.Shading { .color(Color.white.opacity(min(1, max(0, a)))) }
        func arrow(_ y: Double) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y - 9))
            p.addLine(to: CGPoint(x: 0, y: y + 7))
            p.move(to: CGPoint(x: -6, y: y + 1))
            p.addLine(to: CGPoint(x: 0, y: y + 7))
            p.addLine(to: CGPoint(x: 6, y: y + 1))
            return p
        }
        if idle > 0.02 {
            // 空闲：向下的箭头，轻轻上下动
            var p = arrow(sin(t * 1.6) * 1.5 - 1)
            p.move(to: CGPoint(x: -7, y: 12))
            p.addLine(to: CGPoint(x: 7, y: 12))
            c.stroke(p, with: ink(idle), style: pen)
        }
        if parsing > 0.02 {
            // 解析：转动的弧线
            c.stroke(arc(0, 0, 9, t * 6, t * 6 + 4.2), with: ink(parsing), style: pen)
            c.fill(circle(0, 0, 2.2), with: ink(parsing))
        }
        if waiting > 0.02 {
            // 等回答：三个点依次亮
            for i in 0..<3 {
                let a = waiting * (0.35 + 0.65 * max(0, sin(t * 3.5 - Double(i) * 0.9)))
                c.fill(circle(Double(i - 1) * 8, 0, 2.6), with: ink(a))
            }
        }
        if downloading > 0.02 {
            // 下载：箭头一次次从上面穿过去
            let q = (t * 1.1).truncatingRemainder(dividingBy: 1)
            c.stroke(arrow(-22 + 44 * q), with: ink(downloading * sin(q * Double.pi)), style: pen)
        }
        if finished > 0.02 {
            // 完成：对勾一笔画出来
            var p = Path()
            p.move(to: CGPoint(x: -9, y: 0))
            p.addLine(to: CGPoint(x: -3, y: 7))
            p.addLine(to: CGPoint(x: 9, y: -7))
            c.stroke(p.trimmedPath(from: 0, to: min(1, finished)), with: ink(1), style: pen)
        }
        if failed > 0.02 {
            let z = 7 * failed
            var p = Path()
            p.move(to: CGPoint(x: -z, y: -z))
            p.addLine(to: CGPoint(x: z, y: z))
            p.move(to: CGPoint(x: z, y: -z))
            p.addLine(to: CGPoint(x: -z, y: z))
            c.stroke(p, with: ink(failed), style: pen)
        }
    }
}
