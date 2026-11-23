import AppKit
import SwiftUI

extension PhaseRuns {
    /// The whole story of one Phase: where it came from, what is built on it, what runs it.
    static func showPhaseDetails(_ p: TeleportProfile, name: String, window: WindowModel?) async {
        if BeamPhaseLists.shared.phaseList(p.proxy) == nil { await BeamPhaseLists.shared.refreshPhases(p) }
        let rel = PhaseRelations.of(p.proxy, name)
        let title = "Phase \(BeamsUI.phaseName(name))"
        let sub = p.cluster.nilIfEmpty ?? p.proxy
        Modal.sheet(window, title: title, width: 660, resizable: true) { handle in
            DialogScaffold(title: title, subtitle: sub, width: 660) {
                PhaseDetailsBody(name: name, rel: rel)
            } footer: {
                Spacer()
                Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            }
        }
    }
}

private func when(_ ms: Double?) -> String { ms.map { HostWatch.localeString($0) } ?? "" }

private struct PhaseDetailsBody: View {
    let name: String
    let rel: PhaseRelationsInfo

    var body: some View {
        let me = rel.chain.last
        VStack(alignment: .leading, spacing: 14) {
            if me == nil || me!.base || me!.gone {
                line("\(name) is not in this cluster’s Phase list (tsh phase ls) — deleted, or someone else’s.", dim: true)
                if !rel.builds.isEmpty { section("Builds started from ServerLife") { ForEach(rel.builds) { buildLine($0) } } }
            } else if let me, let ph = me.phase {
                section("History") {
                    ForEach(Array(rel.chain.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(i == 0 ? "●" : s.how == "fork" ? "⑂" : "↳").foregroundStyle(Theme.shared.p.muted).frame(width: 14)
                            Text(s.name).font(.system(size: 12, weight: i == rel.chain.count - 1 ? .semibold : .regular))
                            Text(stepText(s, i)).font(.system(size: 11)).foregroundStyle(Theme.shared.p.muted)
                        }.padding(.vertical, 1)
                    }
                }
                section("This snapshot") {
                    line(ph.digest.isEmpty ? "no snapshot saved yet" : "\(ph.name)@\(ph.digest)")
                    if !ph.lastError.isEmpty { line(ph.lastError, color: Theme.shared.p.red) }
                    if let n = ph.nextBuild { line("next rebuild \(when(n))", dim: true) }
                    line([ph.region, ph.owner].filter { !$0.isEmpty }.joined(separator: " · "), dim: true)
                    if !ph.roles.isEmpty { line("roles delegated to its builds: " + ph.roles.joined(separator: ", "), dim: true) }
                }
                section("Built or forked from it (\(rel.children.count))") {
                    if rel.children.isEmpty { line("none", dim: true) }
                    ForEach(rel.children) { c in
                        line("\(c.how == "fork" ? "⑂ forked" : "↳ built on it"): \(c.phase.name) · \(c.phase.state)"
                             + (c.phase.publishedAt.map { " · saved " + when($0) } ?? ""))
                    }
                }
                section("Beams running it (\(rel.beams.count))") {
                    if rel.beams.isEmpty { line("none", dim: true) }
                    ForEach(Array(rel.beams.enumerated()), id: \.offset) { _, b in line(beamText(b)) }
                }
                section("Builds started from ServerLife (\(rel.builds.count))") {
                    if rel.builds.isEmpty { line("none recorded here", dim: true) }
                    ForEach(rel.builds) { buildLine($0) }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func stepText(_ s: PhaseStep, _ i: Int) -> String {
        if s.base { return "base image" }
        if s.gone { return "no longer listed" }
        let ph = s.phase
        return [i > 0 ? (s.how == "fork" ? "forked from the one above" : "built on the one above") : "",
                ph?.strategy ?? "", ph?.state ?? "", ph?.publishedAt.map { "saved " + when($0) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func beamText(_ b: Beam) -> String {
        let exp = Beams.expiresIn(b)
        var s = "\(b.id) · \(b.region)" + (exp.isEmpty ? "" : " · " + exp)
        if let at = b.phase.firstIndex(of: "@") { s += " · snapshot " + String(b.phase[b.phase.index(after: at)...].prefix(19)) }
        return s
    }

    @ViewBuilder private func buildLine(_ e: PhaseBuildEntry) -> some View {
        let how = e.kind == "edit" ? "edited in place"
            : e.mode == "fork" ? "forked from \(e.source)" : e.mode == "from" ? "built on \(e.source)" : "from the base image"
        let file = !e.commandsFile.isEmpty ? "command file \(e.commandsFile)" : (e.kind == "add" ? "build console" : "")
        let text = [when(e.startedAt), how, file, e.result].filter { !$0.isEmpty }.joined(separator: " · ")
            + (e.error.isEmpty ? "" : "\n" + e.error)
        line(text, dim: e.result != "saved", color: e.result == "failed" ? Theme.shared.p.red : nil)
    }

    private func line(_ text: String, dim: Bool = false, color: Color? = nil) -> some View {
        Text(text).font(.system(size: 12))
            .foregroundStyle(color ?? (dim ? Theme.shared.p.muted : Theme.shared.p.text))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 1)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.bottom, 4)
            rows()
        }
    }
}
