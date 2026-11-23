import SwiftUI

/// `.sb-scanning`: the radar shown while the first inventory read is under way.
struct SBRadar: View {
    let text: String
    var body: some View {
        let p = Theme.shared.p
        VStack(spacing: 10) {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle().fill(p.panel2)
                    Circle().strokeBorder(p.borderSoft, lineWidth: 1).frame(width: 24, height: 24)
                    Circle().strokeBorder(p.borderSoft, lineWidth: 1).frame(width: 50, height: 50)
                    AngularGradient(gradient: Gradient(colors: [p.accent, .clear, .clear]),
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(360))
                        .clipShape(Circle()).opacity(0.6)
                        .rotationEffect(.degrees((t.truncatingRemainder(dividingBy: 1.8) / 1.8) * 360 - 70))
                    blip(t, delay: 0, x: 36, y: 16)
                    blip(t, delay: 0.9, x: 16, y: 36)
                    blip(t, delay: 1.7, x: 20, y: 20)
                }
                .frame(width: 54, height: 54)
                .overlay(Circle().strokeBorder(p.borderSoft, lineWidth: 1))
            }
            Text(text).font(.system(size: 12)).foregroundStyle(p.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// `sb-radar-blip`: 0 → 1.3 → 1 → gone over 2.6 s.
    private func blip(_ t: Double, delay: Double, x: CGFloat, y: CGFloat) -> some View {
        let f = ((t - delay).truncatingRemainder(dividingBy: 2.6) + 2.6).truncatingRemainder(dividingBy: 2.6) / 2.6
        let (o, s): (Double, Double) = f < 0.12 ? (f / 0.12, 0.5 + 0.8 * f / 0.12)
            : f < 0.30 ? (1 - 0.2 * (f - 0.12) / 0.18, 1.3 - 0.3 * (f - 0.12) / 0.18)
            : f < 0.55 ? (0.8 * (1 - (f - 0.30) / 0.25), 1) : (0, 1)
        return Circle().fill(Theme.shared.p.accent).frame(width: 5, height: 5)
            .scaleEffect(s).opacity(o)
            .position(x: x, y: y)
    }
}

/// A kube cluster nested in its Teleport cluster's group: the kube owner's
/// row when it has one (`kubeContextRow` / `availableClusterRow`), else the
/// bare name with its ☸.
struct SBKubeRow: View {
    let window: WindowModel
    let sw: SidebarWindow
    let item: SBHostItem
    @StateObject private var hover = LocalFlag()

    var body: some View {
        let ctx = SBKubeRowContext(depth: item.depth, folder: item.folder != nil, groupKey: item.groupKey,
                                   watched: HostWatch.isWatched(item.host))
        if let make = SidebarHooks.kubeClusterRow, let v = make(item.host, ctx, window) {
            v
        } else {
            bare
        }
    }

    private var bare: some View {
        let p = Theme.shared.p
        let h = item.host
        return HStack(spacing: SBZoom.px(7)) {
            Text("☸").font(SBZoom.font(11)).foregroundStyle(p.accent)
            Text(h.name).font(SBZoom.font(12.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let marks = SidebarHooks.kubeMarks?(h) { marks }
            if h.extra["requestable"]?.bool == true { SBTag(text: "request", kind: .req) }
        }
        .foregroundStyle(hover.on ? p.text : p.textDim)
        .padding(.leading, SBZoom.px(20 + CGFloat(item.depth) * 14)).padding(.trailing, 10).padding(.vertical, SBZoom.px(5))
        .background(hover.on ? p.panel2 : .clear)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .help("Kubernetes cluster \(h.name)" + (h.cluster.map { "\ncluster: \($0)" } ?? ""))
        .onTapGesture(count: 2) {
            Actions.shared.perform("kube-browser", window: window, host: h,
                                   args: ["context": h.extra["context"]?.string ?? h.name])
        }
        .sbContextMenu {
            let m = NSMenu()
            Actions.shared.perform("kube-host-menu", window: window, host: h,
                                   args: ["menu": m, "context": h.extra["context"]?.string ?? h.name])
            var items: [CtxItem] = []
            if let cloud = SidebarHooks.kubeCloudMenuItem?(h, window) { items.append(cloud) }
            if !m.items.isEmpty { m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil); return [] }
            return items
        }
    }
}

/// The "AI assistant" row in the Local group (sidebar.js `localAiRows`),
/// drawn by the AI owner (`ai-sidebar-row`); nothing until it answers.
struct SBAIRow: View {
    let window: WindowModel
    var body: some View {
        var row: AnyView?
        Actions.shared.perform("ai-sidebar-row", window: window, args: ["reply": { (v: Any?) in row = v as? AnyView }])
        return row ?? AnyView(EmptyView())
    }
}

extension View {
    /// The tabbed beams heading sits where the plain `BEAMS` one did.
    func sbBeamHeadPadding() -> some View {
        self.padding(.leading, SBZoom.px(20)).padding(.trailing, 10).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Theme.shared.p.borderSoft.frame(height: 1) }
            .padding(.top, 2)
    }
}
