import AppKit
import QuartzCore
import SwiftUI

/// The registry — over thirty of them, picked at random, never twice in a
/// row (paneclose.js `ANIMATIONS`, keyframes from styles.css `pc-*`).
/// Filters CSS has and Core Animation does not (blur, hue-rotate, sepia)
/// are washes of white, black or rust over the picture.
@MainActor
extension PaneClose {
    static func rand(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + CGFloat.random(in: 0...1) * (b - a) }
    static func cg(_ c: Color) -> CGColor { NSColor(c).cgColor }

    enum Ease { case easeIn, easeOut, inBack, launch }
    static func timing(_ e: Ease) -> CAMediaTimingFunction {
        switch e {
        case .easeIn: return CAMediaTimingFunction(controlPoints: 0.42, 0, 1, 1)
        case .easeOut: return CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
        case .inBack: return CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        case .launch: return CAMediaTimingFunction(controlPoints: 0.2, 0, 0.4, 1)
        }
    }

    static func anim(_ layer: CALayer, _ key: String, _ values: [Any], _ times: [Double], _ dur: Double,
                             _ ease: Ease, delay: Double = 0) {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.duration = dur
        a.timingFunction = timing(ease)
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: key)
    }

    /// Run keyframes on the pane's picture. `anchor` is CSS's transform-origin.
    static func keys(_ st: Stage, _ ms: Double, _ ease: Ease, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
                     _ frames: [PCKey]) -> Double {
        let el = st.el, size = st.rect.size, dur = ms / 1000
        el.anchorPoint = anchor
        el.position = CGPoint(x: st.rect.minX + anchor.x * size.width, y: st.rect.minY + anchor.y * size.height)
        var all = frames
        if all.first?.t != 0 { all.insert(PCKey(t: 0), at: 0) }
        let times = all.map(\.t)
        anim(el, "transform", all.map { NSValue(caTransform3D: $0.transform(size)) }, times, dur, ease)
        anim(el, "opacity", all.map { $0.op }, times, dur, ease)
        for (key, colour) in [(\PCKey.white, CGColor.white), (\PCKey.black, CGColor.black),
                              (\PCKey.tint, CGColor(red: 0.45, green: 0.25, blue: 0.08, alpha: 1))] {
            let vals = all.map { $0[keyPath: key] }
            guard vals.contains(where: { $0 > 0 }) else { continue }
            let wash = CALayer()
            wash.frame = el.bounds
            wash.backgroundColor = colour
            wash.opacity = 0
            el.addSublayer(wash)
            anim(wash, "opacity", vals, times, dur, ease)
        }
        return ms / 1000
    }

    static func plain(_ name: String, _ ms: Double, _ ease: Ease, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
                              _ frames: [PCKey]) -> Effect {
        Effect(name: name) { keys($0, ms, ease, anchor: anchor, frames) }
    }

    static func plain(_ name: String, _ ms: Double, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
                      _ frames: [PCKey]) -> Effect {
        plain(name, ms, .easeIn, anchor: anchor, frames)
    }

    /// clip-path: circle(r0 at c) → circle(0 at c).
    static func iris(_ name: String, _ ms: Double, at c: CGPoint, from r0: CGFloat) -> Effect {
        Effect(name: name) { st in
            let w = st.rect.width, h = st.rect.height
            let centre = CGPoint(x: c.x * w, y: c.y * h)
            // CSS: a percentage radius is of sqrt((w² + h²) / 2).
            let r = r0 * sqrt((w * w + h * h) / 2)
            func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r), transform: nil) }
            let mask = CAShapeLayer()
            mask.frame = st.el.bounds
            mask.path = circle(0.01)
            st.el.mask = mask
            anim(mask, "path", [circle(r), circle(0.01)], [0, 1], ms / 1000, .easeIn)
            return ms / 1000
        }
    }

    /// Travel to a point, as the `--pc-tx/--pc-ty` keyframes do.
    static func travel(_ name: String, _ ms: Double, _ ease: Ease, target: @escaping (Stage) -> CGPoint,
                               _ frames: @escaping (CGFloat, CGFloat) -> [PCKey]) -> Effect {
        Effect(name: name) { st in
            let t = target(st)
            return keys(st, ms, ease, frames(t.x - st.rect.midX, t.y - st.rect.midY))
        }
    }

    /// Bottom-left-ish — there is no literal trash can on screen, so this is it.
    static func trashPoint(_ st: Stage) -> CGPoint { CGPoint(x: rand(24, 64), y: st.bounds.height - rand(24, 64)) }

    /// A small piece of debris over the pane, falling its own way.
    static func fragment(_ st: Stage, _ r: CGRect, colour: CGColor, border: CGColor? = nil, round: CGFloat = 0,
                                 fx: CGFloat, fy: CGFloat, rot: CGFloat, ms: Double, delay: Double, ease: Ease,
                                 startOpacity: Float = 1) {
        let f = CALayer()
        f.frame = r.offsetBy(dx: st.rect.minX, dy: st.rect.minY)
        f.backgroundColor = colour
        f.cornerRadius = round
        if let border { f.borderColor = border; f.borderWidth = 1 }
        st.root.addSublayer(f)
        let end = PCKey(px: fx, py: fy, rot: rot, op: 0)
        anim(f, "transform", [NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: end.transform(r.size))],
             [0, 1], ms / 1000, ease, delay: delay / 1000)
        anim(f, "opacity", [startOpacity, 0], [0, 1], ms / 1000, ease, delay: delay / 1000)
    }

    static let effects: [Effect] = [
        plain("shrink-fade", 500, [PCKey(s: 0, op: 0)]),
        plain("spin-fade", 600, [PCKey(s: 0, rot: 720, op: 0)]),
        plain("drop", 700, .inBack, [PCKey(y: 1.7, rot: 26, op: 0)]),
        plain("launch", 650, .launch, [PCKey(y: -1.7, rot: -18, op: 0)]),
        plain("slide-left", 600, [PCKey(x: -1.5, rot: -24, op: 0)]),
        plain("slide-right", 600, [PCKey(x: 1.5, rot: 24, op: 0)]),
        iris("iris", 550, at: CGPoint(x: 0.5, y: 0.5), from: 0.75),
        iris("iris-corner", 600, at: CGPoint(x: 1, y: 1), from: 1),
        plain("melt", 800, anchor: CGPoint(x: 0.5, y: 1), [PCKey(t: 0.6, sy: 0.5, skew: 4), PCKey(sy: 0.04, skew: 9, op: 0)]),
        plain("vacuum", 650, [PCKey(s: 0, rot: 1080, op: 0)]),
        plain("blackhole", 750, [PCKey(t: 0.6, rot: 216, black: 0.2), PCKey(s: 0, rot: 360, op: 0, black: 1)]),
        plain("crt-off", 550, [PCKey(t: 0.55, sy: 0.04, white: 0.5), PCKey(sx: 0, sy: 0.04, op: 0, white: 0.8)]),
        plain("glitch", 600, [PCKey(t: 0.1, px: -6), PCKey(t: 0.2, px: 5), PCKey(t: 0.32, px: -9, op: 0.7),
                              PCKey(t: 0.5, px: 7, op: 0.8), PCKey(t: 0.7, px: -4, op: 0.4), PCKey(px: 12, op: 0)]),
        plain("static", 550, [PCKey(t: 0.12, op: 0.2), PCKey(t: 0.22, op: 1), PCKey(t: 0.34, op: 0.3, white: 0.2),
                              PCKey(t: 0.5, op: 0.9), PCKey(t: 0.7, op: 0.15), PCKey(op: 0)]),
        plain("overexpose", 500, [PCKey(t: 0.4, white: 0.55), PCKey(s: 1.06, op: 0, white: 0.9)]),
        plain("rust", 900, [PCKey(s: 0.96, op: 0, tint: 0.75)]),
        plain("freeze", 700, [PCKey(t: 0.6, s: 0.97, white: 0.3), PCKey(t: 0.82, s: 0.94, white: 0.55), PCKey(s: 0.9, op: 0, white: 0.7)]),
        plain("fold-top", 600, anchor: CGPoint(x: 0.5, y: 0), [PCKey(y: -0.08, rotX: -100, op: 0)]),
        plain("fold-bottom", 650, anchor: CGPoint(x: 0.5, y: 1), [PCKey(y: 0.08, rotX: 100, op: 0)]),
        plain("book-close", 600, anchor: CGPoint(x: 0, y: 0.5), [PCKey(rotY: 100, op: 0)]),
        plain("warp", 550, [PCKey(s: 2.6, op: 0)]),
        plain("implode", 450, [PCKey(t: 0.15, s: 1.05, white: 0.6), PCKey(s: 0, op: 0, black: 0.5)]),
        plain("sink", 700, [PCKey(y: 0.35, sy: 0.25, op: 0, black: 0.5)]),
        plain("tumble", 700, [PCKey(t: 0.5, s: 0.5, sy: 0.7, rot: 270), PCKey(s: 0, sy: 0.7, rot: 540, op: 0)]),
        plain("wilt", 900, [PCKey(y: 0.5, sy: 0.4, rot: 14, op: 0)]),
        plain("drain", 650, anchor: CGPoint(x: 0.5, y: 1), [PCKey(sy: 0, op: 0, black: 0.4)]),
        plain("levitate", 650, [PCKey(t: 0.4, y: -0.16, s: 1.03), PCKey(y: -0.42, s: 0.2, op: 0)]),
        plain("page-turn", 600, anchor: CGPoint(x: 1, y: 0.5), [PCKey(x: -0.08, rotY: -100, op: 0)]),
        plain("jelly-pop", 650, [PCKey(t: 0.3, sx: 1.15, sy: 0.85), PCKey(t: 0.5, sx: 0.85, sy: 1.15),
                                 PCKey(t: 0.7, sx: 1.05, sy: 0.95), PCKey(s: 0, op: 0)]),
        plain("corner-twist", 600, [PCKey(x: 0.2, y: 0.2, s: 0, rot: 300, op: 0)]),
        travel("toss-trash", 900, .inBack, target: { trashPoint($0) }) { tx, ty in
            [PCKey(t: 0.55, px: tx * 0.55, py: ty * 0.4, s: 0.55, rot: -220), PCKey(px: tx, py: ty, s: 0.04, rot: -560, op: 0)]
        },
        travel("spiral-drain", 800, .easeIn, target: { CGPoint(x: $0.rect.midX, y: $0.bounds.height + 40) }) { tx, ty in
            [PCKey(t: 0.7, px: tx * 0.6, py: ty * 0.5, s: 0.4, rot: 540), PCKey(px: tx, py: ty, s: 0, rot: 1080, op: 0)]
        },
        travel("fly-corner", 750, .easeIn, target: { st in
            let w = st.bounds.width, h = st.bounds.height
            return [CGPoint(x: 24, y: 24), CGPoint(x: w - 24, y: 24), CGPoint(x: 24, y: h - 24), CGPoint(x: w - 24, y: h - 24)].randomElement()!
        }) { tx, ty in [PCKey(px: tx, py: ty, s: 0.08, rot: 260, op: 0)] },
    ] + debrisEffects
}
