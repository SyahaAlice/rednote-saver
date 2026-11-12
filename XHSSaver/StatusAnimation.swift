import SwiftUI

/// 下载页顶上的状态动画：三个纯色的圆片，加上圆环和弧线，用 Canvas 实时画，不带任何素材。
/// 两条规矩（用户定的）：圆片从头到尾都是正圆，只变大小、不拉长不压扁；移动只走直线或圆周。
/// 只是装饰：不接受点按，辅助功能里看不到（状态由 `phase` 标识给出）。
/// 设置页可以关掉；关掉后这块地方留空，下面的输入框不挪位置
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
    @AppStorage(Prefs.animationOnKey) private var enabled = true
    @State private var model = StatusAnimationModel()

    var body: some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused || reduceMotion)) { line in
                Canvas { g, size in
                    model.render(g, size: size, dark: scheme == .dark, date: line.date, kind: kind, progress: progress)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

/// 动画的全部状态和画法。是引用类型：每一帧在 Canvas 里直接改，不经过 SwiftUI 的状态更新
final class StatusAnimationModel {
    private typealias Kind = StatusAnimation.Kind

    /// 一个圆片的全部数值，按这个顺序放在数组里：0 x、1 y、2 半径、3 不透明度、4…6 颜色（红绿蓝，0…255）。
    /// 每个数值各带一根弹簧，到位时会过冲一点再回来；三个圆片的弹簧松紧不同，所以有先有后
    private struct Disc {
        var v: [Double] = []
        var vel = [Double](repeating: 0, count: 7)
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

    /// 进度圆环的半径
    private let ring = 34.0
    private var discs = [Disc(k: 230, d: 20), Disc(k: 180, d: 17), Disc(k: 140, d: 15)]
    private var requested = Kind.idle
    private var shown = Kind.idle
    private var since = 0.0
    private var last = 0.0
    private var t = 0.0
    private var prog = 0.0
    private var ripple = 9.0
    /// 每个状态显示了多少（0…1），线条跟着它淡入淡出。下标是 Kind.rawValue
    private var amt: [Double] = [1, 0, 0, 0, 0, 0, 0]
    /// 空闲的四个构图各自显示了多少
    private var pose: [Double] = [1, 0, 0, 0]

    private func enter(_ k: Kind) {
        guard k != shown else { return }
        shown = k
        since = t
        ripple = 0
    }

    private func tint(_ c: [Double], _ alpha: Double) -> Color {
        Color(.sRGB, red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, opacity: min(1, max(0, alpha)))
    }

    /// 空闲时现在轮到第几个构图（每个 3.8 秒）
    private var idlePose: Int { Int(t / 3.8) % 4 }

    /// 心跳：一下猛的，然后衰减着抖两下。i 越大越晚开始
    private func beat(_ i: Int) -> Double {
        var q = ((t - Double(i) * 0.16) / 1.9).truncatingRemainder(dividingBy: 1)
        if q < 0 { q += 1 }
        return exp(-q * 5) * sin(q * 15)
    }

    /// 两圈轨道上的角度：匀速之外叠两个互不合拍的快慢变化，看不出重复
    private func orbitAngle(_ n: Int) -> Double {
        if n == 1 {
            let wobble: Double = 0.75 * sin(t * 0.7) + 0.3 * sin(t * 1.9)
            return t * 0.9 + wobble
        }
        let wobble: Double = 0.9 * sin(t * 0.43 + 1) + 0.25 * sin(t * 1.3)
        return 2 - t * 0.6 - wobble
    }

    private func orbitSpeed(_ n: Int) -> Double {
        if n == 1 {
            let wobble: Double = 0.525 * cos(t * 0.7) + 0.57 * cos(t * 1.9)
            return 0.9 + wobble
        }
        let wobble: Double = 0.387 * cos(t * 0.43 + 1) + 0.325 * cos(t * 1.3)
        return 0.6 + wobble
    }

    /// 进度圆环头上的角度。不知道进度时一直转
    private func headAngle(known: Bool) -> Double {
        known ? -Double.pi / 2 + 2 * Double.pi * prog : t * 3.2
    }

    /// 第 i 个圆片现在该是什么样
    private func target(_ i: Int, _ w: Double, _ h: Double, _ pal: Palette, known: Bool) -> [Double] {
        let cx = w / 2, cy = h / 2
        let age = t - since
        let di = Double(i), k = Double(i - 1)
        var x = cx, y = cy, r = 10.0, alpha = 1.0
        var c = i == 0 ? pal.violet : (i == 1 ? pal.rose : pal.lav)

        switch shown {
        case .idle:
            alpha = 0.82
            switch idlePose {
            case 0:
                // 三个圆叠成一朵：沿同一个圆周转（半径不变），时快时慢；大小轮流起伏
                let a = t * 0.5 + 0.7 * sin(t * 0.8) + di * 2.094
                x = cx + cos(a) * 16; y = cy + sin(a) * 16
                r = 24 + 4 * sin(t * 1.6 - di * 2.094)
            case 1:
                // 一大两小沿两圈轨道绕；小圆掠过右侧时中间的大圆鼓一下
                if i == 0 {
                    r = 14 + 3.5 * pow(max(0, cos(orbitAngle(1))), 6)
                } else {
                    let a = orbitAngle(i), rad = i == 1 ? 36.0 : 56.0
                    x = cx + cos(a) * rad; y = cy + sin(a) * rad
                    r = i == 1 ? 8 : 5.5
                }
                alpha = 0.95
            case 2:
                // 在一条水平直线上来回穿梭：同一个节拍，三个圆错开三分之一拍，幅度不同，所以互相穿过、叠在一起又分开
                let reach: Double = i == 0 ? 60 : (i == 1 ? 42 : 66)
                x = cx + sin(t * 1.7 + di * 2.094) * reach
                r = i == 0 ? 21 : (i == 1 ? 15 : 11)
                alpha = 0.85
            default:
                // 同心圆，像心跳一样由里向外一圈推一圈
                let base = i == 0 ? 44.0 : (i == 1 ? 29.0 : 14.0)
                let swing = i == 0 ? 0.1 : (i == 1 ? 0.15 : 0.3)
                r = base * (1 + swing * beat(2 - i))
                alpha = i == 0 ? 0.45 : (i == 1 ? 0.7 : 0.95)
            }
        case .parsing:
            // 三个小点绕圈互相追
            let a = t * 5.2 + di * 2.094
            x = cx + cos(a) * 24; y = cy + sin(a) * 24
            r = 6.5
        case .waiting:
            // 三个点轮流跳，中间那个是黄色
            x = cx + k * 28
            y = cy - pow(max(0, sin(t * 3.2 - di * 0.7)), 3) * 16
            r = 7.5
            if i == 1 { c = pal.amber }
        case .downloading, .saving:
            // 0：中间的圆，随进度变大；1：下载时一遍遍往下落的小点，保存时绕圈的小点；2：顶在进度头上的小圆
            let save = shown == .saving
            if i == 0 {
                r = known ? 9 + 14 * prog : 12 + 2 * sin(t * 2)
                c = save ? pal.rose : pal.violet
                alpha = 0.28
            } else if i == 1 {
                r = 4
                if save {
                    x = cx + cos(t * 4) * 13; y = cy + sin(t * 4) * 13
                    c = pal.rose
                } else {
                    let f = (t * 1.3).truncatingRemainder(dividingBy: 1)
                    y = cy - 16 + 32 * f
                    c = pal.violet
                    alpha = sin(Double.pi * f)
                }
            } else {
                let a = headAngle(known: known)
                x = cx + cos(a) * ring; y = cy + sin(a) * ring
                r = 7 + 1.5 * sin(t * 6)
                c = save ? pal.violet : pal.rose
            }
        case .finished, .failed:
            // 合成一个圆：完成是绿的，失败是红的、左右晃几下
            let ok = shown == .finished
            c = ok ? pal.green : pal.rose
            x = cx + (ok ? 0 : sin(age * 34) * 9 * exp(-age * 4))
            if i == 0 {
                r = 29
            } else {
                alpha = 0
            }
        }
        return [x, y, r, alpha, c[0], c[1], c[2]]
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
        for k in Kind.allCases {
            amt[k.rawValue] += ((shown == k ? 1 : 0) - amt[k.rawValue]) * rate
        }
        for n in 0..<4 {
            pose[n] += ((shown == .idle && idlePose == n ? 1 : 0) - pose[n]) * rate
        }
        if shown == .downloading || shown == .saving {
            prog += ((progress ?? 0) - prog) * (1 - exp(-dt * 6))
        } else {
            prog = 0
        }

        let pal = dark ? Palette.dark : Palette.light
        let w = Double(size.width), h = Double(size.height)
        let cx = w / 2, cy = h / 2
        let known = progress != nil
        for i in discs.indices {
            let to = target(i, w, h, pal, known: known)
            if discs[i].v.isEmpty { discs[i].v = to }
            for j in 0..<7 {
                let force = (to[j] - discs[i].v[j]) * discs[i].k - discs[i].vel[j] * discs[i].d
                discs[i].vel[j] += force * dt
                discs[i].v[j] += discs[i].vel[j] * dt
            }
        }

        // 画一段圆弧（从 a0 到 a1，角度增大的方向）、一整圈、一个圆点
        func arc(_ radius: Double, _ a0: Double, _ a1: Double, _ color: Color, _ width: Double) {
            var p = Path()
            p.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                     startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        func circle(_ radius: Double, _ color: Color, _ width: Double) {
            let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            g.stroke(Path(ellipseIn: rect), with: .color(color), style: StrokeStyle(lineWidth: width))
        }
        func dot(_ x: Double, _ y: Double, _ radius: Double, _ color: Color) {
            let rr = max(0.1, radius)
            g.fill(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)), with: .color(color))
        }

        // —— 线条，都画在圆片下面 ——
        // 空闲：外圈两段细弧反着转，两个小点各绕各的；起点的快慢、弧的长短各按不合拍的节奏变
        let idle = amt[Kind.idle.rawValue]
        if idle > 0.02 {
            let s1: Double = t * 0.5 + 0.9 * sin(t * 0.37)
            let l1: Double = 1.3 + 0.8 * sin(t * 0.61 + 1) + 0.3 * sin(t * 1.7)
            let s2: Double = 2 - t * 0.32 - 0.8 * sin(t * 0.29 + 2)
            let l2: Double = 1.0 + 0.6 * sin(t * 0.83) + 0.25 * sin(t * 1.4 + 2)
            arc(72, s1, s1 + l1, tint(pal.violet, 0.28 * idle), 2)
            arc(80, s2, s2 + l2, tint(pal.rose, 0.24 * idle), 2)
            let d1: Double = t * 0.8 + 3 + 1.1 * sin(t * 0.45)
            let d2: Double = -t * 0.55 - 0.9 * sin(t * 0.5 + 1)
            dot(cx + cos(d1) * 72, cy + sin(d1) * 72, 3.5, tint(pal.amber, 0.9 * idle))
            dot(cx + cos(d2) * 80, cy + sin(d2) * 80, 2.5, tint(pal.lav, 0.9 * idle))
        }
        // 空闲的第二个构图：两圈轨道，小圆身后的亮弧跑得越快拖得越长
        if pose[1] > 0.02 {
            circle(36, tint(pal.rose, 0.16 * pose[1]), 1.5)
            circle(56, tint(pal.lav, 0.22 * pose[1]), 1.5)
            let a1 = orbitAngle(1), t1 = 0.25 + 1.1 * max(0, orbitSpeed(1))
            arc(36, a1 - t1, a1, tint(pal.rose, 0.55 * pose[1]), 2.5)
            let a2 = orbitAngle(2), t2 = 0.2 + 1.3 * max(0, orbitSpeed(2))
            arc(56, a2, a2 + t2, tint(pal.lav, 0.7 * pose[1]), 2.5)
        }
        // 解析：每个点身后拖一段弧线
        let parsing = amt[Kind.parsing.rawValue]
        if parsing > 0.02 {
            for s in discs {
                let v = s.v
                let a = atan2(v[1] - cy, v[0] - cx)
                let rad = ((v[0] - cx) * (v[0] - cx) + (v[1] - cy) * (v[1] - cy)).squareRoot()
                arc(rad, a - 1.1, a, tint([v[4], v[5], v[6]], 0.32 * parsing), 3.5)
            }
        }
        // 等待：脚下一条细线
        let waiting = amt[Kind.waiting.rawValue]
        if waiting > 0.02 {
            var p = Path()
            p.move(to: CGPoint(x: cx - 48, y: cy + 11))
            p.addLine(to: CGPoint(x: cx + 48, y: cy + 11))
            g.stroke(p, with: .color(tint(pal.violet, 0.2 * waiting)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        // 下载、保存：进度圆环（下载是紫的，保存是粉的）。不知道进度时是一段弧一直转
        let down = amt[Kind.downloading.rawValue], save = amt[Kind.saving.rawValue]
        let busy = min(1, down + save)
        if busy > 0.02 {
            let m = save / max(0.001, down + save)
            let rc = [0, 1, 2].map { pal.violet[$0] + (pal.rose[$0] - pal.violet[$0]) * m }
            circle(ring, tint(rc, 0.16 * busy), 6)
            if !known {
                let a = headAngle(known: false)
                arc(ring, a - 1.4, a, tint(rc, busy), 6)
            } else if prog > 0.003 {
                arc(ring, -Double.pi / 2, -Double.pi / 2 + 2 * Double.pi * prog, tint(rc, busy), 6)
            }
        }
        // 换状态时荡开的一圈
        if ripple < 0.7 {
            let v = discs[0].v
            circle(30 + ripple * 120, tint([v[4], v[5], v[6]], (1 - ripple / 0.7) * 0.35), 2)
        }

        // 圆片：始终是正圆
        for s in discs where s.v[3] > 0.02 {
            let v = s.v
            dot(v[0], v[1], v[2], tint([v[4], v[5], v[6]], v[3]))
        }

        // 完成的勾、失败的叉：画在第一个圆上，跟着它一起弹
        let finished = amt[Kind.finished.rawValue], failed = amt[Kind.failed.rawValue]
        guard finished > 0.03 || failed > 0.03 else { return }
        let a = discs[0].v
        var c = g
        c.translateBy(x: a[0], y: a[1])
        c.scaleBy(x: a[2] / 29, y: a[2] / 29)
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
