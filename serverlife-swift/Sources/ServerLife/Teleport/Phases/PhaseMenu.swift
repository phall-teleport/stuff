import AppKit

/// sidebar.js `phaseGroupKeyFor` / phasepicker.js `phaseGroupKey`: the group
/// Phase folders live in — its own namespace, not a host's: a Phase folder and
/// a host folder share the mechanism and nothing else.
func phaseGroupKey(_ p: TeleportProfile) -> String {
    "phase:" + p.proxy + ((p.home?.isEmpty == false) ? "@" + p.home! : "")
}

/// A Phase, host-shaped only enough to be filed in folders.
func phaseHost(_ p: TeleportProfile, _ ph: BeamPhase) -> Host {
    Host(type: "phase", id: "phase:\(p.proxy):\(ph.name)", name: ph.name)
}

extension PhaseRuns {
    /// beams.js `phaseMenu`: what to do with one Phase.
    static func phaseMenu(_ p: TeleportProfile, _ phase: BeamPhase, groupKey: String?, window: WindowModel?) -> [CtxItem] {
        let rel = PhaseRelations.of(p.proxy, phase.name)
        let folderItem = groupKey.flatMap { SBMenus.folderMenu(phaseHost(p, phase), groupKey: $0, window: window) }
        let ready = phase.state == "ready"
        var items: [CtxItem] = [
            // Its history and its users, at the top: what the menu is about.
            CtxItem("History and beams\u{2026}", icon: "\u{2630}", sub: PhaseRelations.menuSub(rel, phase)) {
                Task { await showPhaseDetails(p, name: phase.name, window: window) }
            },
            .sep,
            CtxItem("Start a beam from it\u{2026}", icon: "+", disabled: !ready,
                    title: ready ? nil : "It is \(phase.state.nilIfEmpty ?? "not ready"); a beam can start from it once it is ready") {
                Task { _ = await BeamsUI.start(p, phase: phase.name, window: window) }
            },
            .sep,
            CtxItem("Fork into a new Phase\u{2026}", icon: "\u{2442}",
                    title: "tsh phase add --fork-from: a new Phase that starts from its saved files") {
                Task { await newPhase(p, mode: "fork", source: phase.name, window: window) }
            },
            CtxItem("Build a new Phase on top of it\u{2026}", icon: "\u{2191}",
                    title: "tsh phase add --from: a new Phase with this one as its base image") {
                Task { await newPhase(p, mode: "from", source: phase.name, window: window) }
            },
        ]
        // Copy and rebuild Phases are not edited in a console: their commands
        // or files are replaced, and they rebuild.
        if phase.strategy == "rebuild" || phase.strategy == "copy" {
            let copy = phase.strategy == "copy"
            items.append(CtxItem(copy ? "Copy its files again\u{2026}" : "Replace its command file\u{2026}", icon: "\u{270E}",
                                 title: copy ? "tsh phase edit --copy: the files copied in again, from its parent"
                                     : "tsh phase edit --commands-file: new commands, rebuilt") {
                Task { await replacePhaseInputs(p, phase, window: window) }
            })
        } else {
            items.append(CtxItem("Edit in a build console\u{2026}", icon: "\u{270E}",
                                 title: "tsh phase edit: change it in place (only while nothing is built from it)") {
                Task { await editPhase(p, name: phase.name, window: window) }
            })
        }
        items.append(CtxItem("Add setups on top of it\u{2026}", icon: "\u{2795}", disabled: !ready,
                             title: "Tools, services and files as new stages built on this Phase (tsh phase apply)") {
            PhaseBuilder.open(p, from: phase.name, window: window)
        })
        // A build still running: its Beam, and saving it from here.
        if !phase.buildBeam.isEmpty {
            items += [
                .sep, .heading("Its build is running"),
                CtxItem("Open its build Beam", icon: "\u{25B6}") { BeamsUI.open(buildBeam(p, phase.buildBeam), window: window) },
                CtxItem("Save a snapshot now", icon: "\u{2193}", title: "tsh phase snapshot in its build Beam — the build keeps going") {
                    Task { await snapshotBuild(p, phase, window: window) }
                },
                CtxItem("Save and finish the build\u{2026}", icon: "\u{2713}", title: "tsh phase snapshot --final") {
                    Task { await snapshotBuild(p, phase, final: true, window: window) }
                },
            ]
        }
        items += [.sep, CtxItem("Copy name", icon: "\u{29C9}") {
            Clipboard.write(phase.name); PHStatus.show("Copied \(phase.name)")
        }]
        if !phase.digest.isEmpty {
            items.append(CtxItem("Copy snapshot (name@digest)", icon: "\u{29C9}",
                                 title: "Starts a beam from exactly this snapshot, even after the Phase is saved again") {
                Clipboard.write("\(phase.name)@\(phase.digest)"); PHStatus.show("Copied the snapshot reference")
            })
        }
        if let folderItem { items += [.sep, folderItem] }
        items += [.sep, CtxItem("Delete Phase\u{2026}", icon: "\u{2715}") {
            Task { await BeamPhaseLists.shared.removePhase(p, phase, window: window) }
        }]
        return items
    }
}
