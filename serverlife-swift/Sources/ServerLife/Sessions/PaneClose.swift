import AppKit
import QuartzCore

/// paneclose.js — pane-close animations: a little theatre for the one moment
/// a terminal pane actually goes away.
///
/// Pure spectacle, and kept strictly separate from the real teardown. By the
/// time `play` runs, the session has already ended and the pane has already
/// been dropped from the layout — the real work is done. All this does is
/// hold a picture of the pane, exactly as it last drew, over the top of the
/// already-reflowed layout for one more moment, doing something destructive
/// and a little theatrical to it.
///
/// Every effect animates the pane *itself* — scale, rotate, clip, fall,
/// fragment — never the surviving panes around it sliding into its place;
/// that reflow already happened instantly, the normal way, underneath.
@MainActor
enum PaneClose {
    /// Off in Settings, or the system asked for less motion: skip the show.
    static var shouldAnimate: Bool {
        if Store.shared.settingJSON("paneCloseAnimations").bool == false { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    struct Shot {
        let image: CGImage
        /// In the content view's top-left coordinates.
        let rect: CGRect
        weak var window: NSWindow?
    }

    /// A picture of the pane as it is now — taken before it leaves the layout.
    static func capture(_ p: SessionPane, in window: NSWindow?) -> Shot? {
        guard let window, let cv = window.contentView else { return nil }
        let r = p.windowFrame.intersection(cv.bounds)
        guard r.width > 4, r.height > 4 else { return nil }
        let local = cv.isFlipped ? r : CGRect(x: r.minX, y: cv.bounds.height - r.maxY, width: r.width, height: r.height)
        guard let rep = cv.bitmapImageRepForCachingDisplay(in: local) else { return nil }
        cv.cacheDisplay(in: local, to: rep)
        guard let img = rep.cgImage else { return nil }
        return Shot(image: img, rect: r, window: window)
    }

    private static var lastIndex = -1

    static func pick() -> Effect {
        var i = 0
        repeat { i = Int.random(in: 0..<effects.count) } while effects.count > 1 && i == lastIndex
        lastIndex = i
        return effects[i]
    }

    /// Play one of the registry's effects on the picture, then take it away.
    static func play(_ shot: Shot) {
        guard let window = shot.window, let cv = window.contentView else { return }
        let stage = PaneCloseStage(frame: cv.bounds)
        stage.autoresizingMask = [.width, .height]
        cv.addSubview(stage, positioned: .above, relativeTo: nil)
        let root = stage.layer!
        let el = CALayer()
        el.frame = shot.rect
        el.contents = shot.image
        el.contentsGravity = .resize
        el.masksToBounds = true
        root.addSublayer(el)
        let ctx = Stage(root: root, el: el, rect: shot.rect, bounds: cv.bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let duration = pick().run(ctx)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.06) { stage.removeFromSuperview() }
    }

    /// What an effect is given: the layer of the pane's picture, where it
    /// is, and a layer over everything for debris.
    struct Stage {
        let root: CALayer
        let el: CALayer
        let rect: CGRect
        let bounds: CGRect
    }

    struct Effect {
        let name: String
        let run: @MainActor (Stage) -> Double
    }

    /// The registry's own names ("there really are at least thirty").
    static var animationNames: [String] { effects.map(\.name) }
}

/// The layer everything plays on, over the window; it takes no clicks.
final class PaneCloseStage: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One moment of a keyframe animation, in CSS's terms: translate (as a
/// fraction of the pane's size, plus points), rotate, scale, opacity, and
/// a wash of white (brightness up) or black (brightness down).
struct PCKey {
    var t: Double = 1
    var x: CGFloat = 0, y: CGFloat = 0, px: CGFloat = 0, py: CGFloat = 0
    var s: CGFloat = 1, sx: CGFloat = 1, sy: CGFloat = 1
    var rot: CGFloat = 0, rotX: CGFloat = 0, rotY: CGFloat = 0, skew: CGFloat = 0
    var op: Float = 1
    var white: Float = 0, black: Float = 0, tint: Float = 0

    func transform(_ size: CGSize) -> CATransform3D {
        var m = CATransform3DIdentity
        m.m34 = -1 / 800
        let d = CGFloat.pi / 180
        if rotX != 0 { m = CATransform3DRotate(m, rotX * d, 1, 0, 0) }
        if rotY != 0 { m = CATransform3DRotate(m, rotY * d, 0, 1, 0) }
        var sk = CATransform3DIdentity
        sk.m21 = tan(skew * d)
        m = CATransform3DConcat(m, sk)
        m = CATransform3DConcat(m, CATransform3DMakeScale(s * sx, s * sy, 1))
        m = CATransform3DConcat(m, CATransform3DMakeRotation(rot * d, 0, 0, 1))
        return CATransform3DConcat(m, CATransform3DMakeTranslation(x * size.width + px, y * size.height + py, 0))
    }
}
