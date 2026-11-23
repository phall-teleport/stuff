import AppKit
import QuartzCore

/// paneclose.js's effects that break the pane into pieces.
@MainActor
extension PaneClose {
    static var debrisEffects: [Effect] { [shatter, crumbleTrash, shred, confetti, ash] }

    /// A short-lived jagged "crack" flash over the pane.
    private static func crackFlash(_ st: Stage) {
        let w = st.rect.width, h = st.rect.height
        let n = Int(rand(5, 8))
        let cx = rand(0.3, 0.7) * w, cy = rand(0.3, 0.7) * h
        let crack = CALayer()
        crack.frame = st.rect
        crack.opacity = 0
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * .pi * 2 + rand(-0.3, 0.3)
            let len = rand(0.5, 0.9)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: cy))
            path.addLine(to: CGPoint(x: cx + cos(a) * w * len * 0.5 + rand(-20, 20), y: cy + sin(a) * h * len * 0.5 + rand(-20, 20)))
            path.addLine(to: CGPoint(x: cx + cos(a) * w * len, y: cy + sin(a) * h * len))
            let s = CAShapeLayer()
            s.path = path
            s.strokeColor = CGColor.white
            s.fillColor = nil
            s.lineWidth = rand(1, 2)
            s.opacity = 0.85
            s.shadowColor = CGColor.black
            s.shadowOpacity = 0.6
            s.shadowRadius = 2
            s.shadowOffset = .zero
            crack.addSublayer(s)
        }
        st.root.addSublayer(crack)
        anim(crack, "opacity", [0, 1, 0.8, 0], [0, 0.15, 0.7, 1], 0.6, .easeOut)
    }

    /// Crack lines flash, then the pane fractures into shards that fall away.
    static var shatter: Effect {
        Effect(name: "shatter") { st in
            crackFlash(st)
            _ = keys(st, 220, .easeOut, [PCKey(t: 0.4, white: 0.4), PCKey(op: 0.85, black: 0.7)])
            let p = Theme.shared.p
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                st.el.isHidden = true
                let cols = 4, rows = 3
                let pw = st.rect.width / CGFloat(cols), ph = st.rect.height / CGFloat(rows)
                for r in 0..<rows {
                    for c in 0..<cols {
                        fragment(st, CGRect(x: CGFloat(c) * pw, y: CGFloat(r) * ph, width: pw, height: ph),
                                 colour: cg(p.panel2), border: cg(p.borderSoft),
                                 fx: rand(-140, 140), fy: rand(160, 420), rot: rand(-260, 260),
                                 ms: Double(rand(500, 850)), delay: Double(rand(0, 90)), ease: .easeIn)
                    }
                }
            }
            return 0.9
        }
    }

    /// Debris crumbles off the edges while the core shrinks and is tossed away.
    static var crumbleTrash: Effect {
        Effect(name: "crumble-trash") { st in
            let t = trashPoint(st)
            let tx = t.x - st.rect.midX, ty = t.y - st.rect.midY
            _ = keys(st, 950, .easeIn, [PCKey(t: 0.5, px: tx * 0.3, py: ty * 0.2, s: 0.8, black: 0.15),
                                        PCKey(px: tx, py: ty, s: 0.05, rot: -300, op: 0, black: 0.5)])
            let w = st.rect.width, h = st.rect.height
            for _ in 0..<18 {
                let edge = ["top", "bottom", "left", "right"].randomElement()!
                let fw = rand(4, 11), fh = rand(4, 11)
                let left = edge == "left" ? rand(-4, 4) : edge == "right" ? w - rand(0, 8) : rand(0, w)
                let top = edge == "top" ? rand(-4, 4) : edge == "bottom" ? h - rand(0, 8) : rand(0, h)
                fragment(st, CGRect(x: left, y: top, width: fw, height: fh), colour: cg(Theme.shared.p.border), round: 1,
                         fx: rand(-60, 60), fy: rand(40, 160), rot: rand(-300, 300),
                         ms: Double(rand(500, 900)), delay: Double(rand(0, 420)), ease: .easeIn, startOpacity: 0.9)
            }
            return 0.95
        }
    }

    /// Peeled into vertical strips, each falling on its own.
    static var shred: Effect {
        Effect(name: "shred") { st in
            st.el.isHidden = true
            let n = 7
            let sw = st.rect.width / CGFloat(n)
            let p = Theme.shared.p
            for i in 0..<n {
                fragment(st, CGRect(x: CGFloat(i) * sw, y: 0, width: sw - 1, height: st.rect.height),
                         colour: cg(p.panel2), border: cg(p.borderSoft),
                         fx: 0, fy: rand(260, 420), rot: rand(-30, 30),
                         ms: Double(rand(550, 800)), delay: Double(i * 35), ease: .inBack)
            }
            return 0.9
        }
    }

    /// A quick pop, then confetti everywhere.
    static var confetti: Effect {
        Effect(name: "confetti") { st in
            _ = keys(st, 280, .easeIn, [PCKey(t: 0.15, s: 1.05, white: 0.6), PCKey(s: 0, op: 0, black: 0.5)])
            let p = Theme.shared.p
            let colours = [p.green, p.amber, p.red, p.textDim, p.border].map(cg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                for _ in 0..<22 {
                    let a = rand(0, .pi * 2), d = rand(60, 220)
                    fragment(st, CGRect(x: st.rect.width / 2 + rand(-10, 10), y: st.rect.height / 2 + rand(-10, 10),
                                        width: rand(5, 9), height: rand(5, 9)),
                             colour: colours.randomElement()!,
                             fx: cos(a) * d, fy: sin(a) * d + rand(40, 120), rot: rand(-400, 400),
                             ms: Double(rand(500, 750)), delay: 0, ease: .easeOut)
                }
            }
            return 0.85
        }
    }

    /// Rises and breaks apart into ash as it fades — the opposite of gravity.
    static var ash: Effect {
        Effect(name: "ash") { st in
            _ = keys(st, 900, .easeOut, [PCKey(t: 0.6, op: 0.5, white: 0.2), PCKey(op: 0, white: 0.35)])
            for _ in 0..<26 {
                fragment(st, CGRect(x: rand(0, st.rect.width), y: rand(0, st.rect.height), width: rand(2, 4), height: rand(2, 4)),
                         colour: cg(Theme.shared.p.muted),
                         fx: rand(-30, 30), fy: rand(-140, -60), rot: 0,
                         ms: Double(rand(500, 850)), delay: Double(rand(0, 400)), ease: .easeOut)
            }
            return 0.9
        }
    }
}
