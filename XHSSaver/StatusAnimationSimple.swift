import SwiftUI

/// 顶部动画的「简洁」样式（默认）：整块只有三个纯色图形——一个圆、一个方块、一条胶囊，没有背景。
/// 三个图形其实都是圆角矩形：宽、高、圆角一变，就能在圆、方块、胶囊、长条之间变形。
/// 每个数值各带一根弹簧，到位时会过冲一点再回来；三个图形的弹簧松紧不同，所以有先有后。
/// 另一种样式（图形多、带背景）在 StatusAnimation.swift 里的 StatusAnimationModel
final class SimpleAnimationModel {
    private typealias Kind = StatusAnimation.Kind

    /// 一个图形的全部数值，按这个顺序放在数组里：
    /// 0 x、1 y、2 宽、3 高、4 圆角、5 转角、6 不透明度、7…9 颜色（红绿蓝，0…255）
    private struct Shape {
        var v: [Double] = []
        var vel = [Double](repeating: 0, count: 10)
        /// 弹簧的松紧和阻尼
        let k: Double
        let d: Double
    }

    private struct Palette {
        let violet: [Double], rose: [Double], lav: [Double], amber: [Double], green: [Double]
        static let light = Palette(violet: [106, 61, 240], rose: [255, 94, 126], lav: [185, 165, 255],
                                   amber: [245, 165, 36], green: [31, 174, 122])
        static let dark = Palette(violet: [138, 102, 255], rose: [255, 111, 140], lav: [168, 146, 255],
                                  amber: [255, 184, 77], green: [53, 201, 144])
    }

    private var shapes = [Shape(k: 230, d: 20), Shape(k: 180, d: 17), Shape(k: 140, d: 15)]
    private var requested = Kind.idle
    private var shown = Kind.idle
    private var since = 0.0
    private var last = 0.0
    private var t = 0.0
    private var prog = 0.0
    private var ripple = 9.0
    private var finished = 0.0
    private var failed = 0.0

    private func enter(_ k: Kind) {
        guard k != shown else { return }
        shown = k
        since = t
        ripple = 0
        // 转角只在图形是方块的时候用，方块转 90° 看着一样：把转过的整圈去掉，免得换状态时倒着转回去好几圈
        let quarter = Double.pi / 2
        for i in shapes.indices where !shapes[i].v.isEmpty {
            shapes[i].v[5] = shapes[i].v[5].truncatingRemainder(dividingBy: quarter)
        }
    }

    private func color(_ v: [Double], _ alpha: Double) -> Color {
        Color(.sRGB, red: v[7] / 255, green: v[8] / 255, blue: v[9] / 255, opacity: min(1, max(0, alpha)))
    }

    /// 第 i 个图形现在该是什么样
    private func target(_ i: Int, _ w: Double, _ h: Double, _ pal: Palette, known: Bool) -> [Double] {
        let cx = w / 2, cy = h / 2
        let age = t - since
        var x = cx, y = cy, sw = 20.0, sh = 20.0, r = 10.0, rot = 0.0, alpha = 1.0
        var c = pal.violet

        switch shown {
        case .idle:
            // 排成一行依次起伏；方块隔几秒转四分之一圈，胶囊一伸一缩
            y = cy + sin(t * 1.5 - Double(i) * 0.9) * 5
            if i == 0 {
                x = cx - 50; sw = 28; sh = 28; r = 14; c = pal.violet
            } else if i == 1 {
                x = cx; sw = 28; sh = 28; r = 8; c = pal.rose
                rot = floor(age / 2.6) * Double.pi / 2
            } else {
                x = cx + 54; sw = 38 + 14 * max(0, sin(t * 1.2)); sh = 14; r = 7; c = pal.lav
            }
        case .parsing:
            // 三个小圆点绕着中心互相追
            let a = t * 5.2 + Double(i) * 2.094
            let rad = 22 + 5 * sin(t * 2.4)
            x = cx + cos(a) * rad; y = cy + sin(a) * rad
            sw = 15; sh = 15; r = 7.5
            c = i == 0 ? pal.violet : (i == 1 ? pal.rose : pal.lav)
        case .waiting:
            // 三个点轮流跳，中间那个是黄色
            let hop = pow(max(0, sin(t * 3.2 - Double(i) * 0.7)), 3) * 14
            x = cx + Double(i - 1) * 28; y = cy - hop
            sw = 15; sh = 15; r = 7.5
            c = i == 0 ? pal.violet : (i == 1 ? pal.amber : pal.lav)
        case .downloading, .saving:
            // 圆拉成轨道，方块是进度条，第三个在进度条头上：下载时是弹着的小球，保存时是滚着的小方块。
            // 不知道进度时，进度条变成一小段来回滑
            let length = min(230, w - 70)
            let x0 = cx - length / 2
            let fill = known ? max(10, length * prog) : length * 0.3
            let fillX = known ? x0 + fill / 2 : cx + sin(t * 2.2) * length * 0.35
            let tipX = known ? x0 + fill : fillX
            if i == 0 {
                x = cx; y = cy + 8; sw = length; sh = 10; r = 5; alpha = 0.18
            } else if i == 1 {
                x = fillX; y = cy + 8; sw = fill; sh = 10; r = 5
            } else if shown == .downloading {
                x = tipX; y = cy - 6 - abs(sin(t * 5.5)) * 14; sw = 16; sh = 16; r = 8; c = pal.rose
            } else {
                x = tipX; y = cy - 7; sw = 18; sh = 18; r = 5; c = pal.rose
                rot = tipX / 9
            }
        case .finished, .failed:
            // 合成一个圆：完成是绿的，失败是红的、左右晃几下
            let ok = shown == .finished
            c = ok ? pal.green : pal.rose
            x = cx + (ok ? 0 : sin(age * 34) * 9 * exp(-age * 4))
            if i == 0 {
                sw = 58; sh = 58; r = 29
            } else {
                alpha = 0
            }
        }
        return [x, y, sw, sh, r, rot, alpha, c[0], c[1], c[2]]
    }

    func render(_ g: GraphicsContext, size: CGSize, dark: Bool, date: Date, kind: StatusAnimation.Kind, progress: Double?) {
        let now = date.timeIntervalSinceReferenceDate
        let dt = last == 0 ? 0 : min(0.033, max(0, now - last))
        last = now
        t += dt
        ripple += dt

        if kind != requested {
            requested = kind
            enter(kind)
        }
        // 完成、失败停 6 秒就回到空闲的样子
        if (shown == .finished || shown == .failed) && t - since > 6 { enter(.idle) }

        let rate = 1 - exp(-dt * 7)
        finished += ((shown == .finished ? 1 : 0) - finished) * rate
        failed += ((shown == .failed ? 1 : 0) - failed) * rate
        if shown == .downloading || shown == .saving {
            prog += ((progress ?? 0) - prog) * (1 - exp(-dt * 6))
        } else {
            prog = 0
        }

        let pal = dark ? Palette.dark : Palette.light
        let w = Double(size.width), h = Double(size.height)
        for i in shapes.indices {
            let to = target(i, w, h, pal, known: progress != nil)
            if shapes[i].v.isEmpty { shapes[i].v = to }
            for j in 0..<10 {
                let force = (to[j] - shapes[i].v[j]) * shapes[i].k - shapes[i].vel[j] * shapes[i].d
                shapes[i].vel[j] += force * dt
                shapes[i].v[j] += shapes[i].vel[j] * dt
            }
        }

        // 换状态时荡开的一圈
        if ripple < 0.7 {
            let rr = 30 + ripple * 120
            let ring = Path(ellipseIn: CGRect(x: w / 2 - rr, y: h / 2 - rr, width: rr * 2, height: rr * 2))
            g.stroke(ring, with: .color(color(shapes[0].v, (1 - ripple / 0.7) * 0.35)), style: StrokeStyle(lineWidth: 2))
        }

        for s in shapes {
            let v = s.v
            guard v[6] > 0.02 else { continue }
            let sw = max(1, v[2]), sh = max(1, v[3])
            let r = max(0, min(v[4], min(sw / 2, sh / 2)))
            var c = g
            c.translateBy(x: v[0], y: v[1])
            c.rotate(by: .radians(v[5]))
            let rect = CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh)
            c.fill(Path(roundedRect: rect, cornerRadius: r), with: .color(color(v, v[6])))
        }

        // 完成的勾、失败的叉：画在第一个图形上，跟着它一起弹
        guard finished > 0.03 || failed > 0.03 else { return }
        let a = shapes[0].v
        var c = g
        c.translateBy(x: a[0], y: a[1])
        c.scaleBy(x: a[2] / 58, y: a[2] / 58)
        let pen = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        if finished > 0.03 {
            var p = Path()
            p.move(to: CGPoint(x: -12, y: 1))
            p.addLine(to: CGPoint(x: -4, y: 9))
            p.addLine(to: CGPoint(x: 12, y: -8))
            c.stroke(p.trimmedPath(from: 0, to: min(1, finished * 1.2)), with: .color(.white), style: pen)
        }
        if failed > 0.03 {
            let z = 9 * failed
            var p = Path()
            p.move(to: CGPoint(x: -z, y: -z))
            p.addLine(to: CGPoint(x: z, y: z))
            p.move(to: CGPoint(x: z, y: -z))
            p.addLine(to: CGPoint(x: -z, y: z))
            c.stroke(p, with: .color(Color.white.opacity(min(1, failed))), style: pen)
        }
    }
}
