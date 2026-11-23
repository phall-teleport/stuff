import AppKit
import SwiftUI

/*
 * A run at a date and time, once or repeating: the command, who it runs as,
 * and its hosts — the ticked ones by id, or a tag query asked again each time
 * — with the retries and staging it had when it was made. Kept in settings
 * (`settings.mxSchedules`), and run while ServerLife is open. A run that fell
 * due while it was closed is not run late, which for a change on servers could
 * be the wrong time; it is counted as missed, and the next one is waited for.
 * (dock.js "Scheduled runs" and mxschedule.js.)
 */
struct MXSchedule: Equatable {
    struct Repeat: Equatable {
        /// minutes | hours | days | weeks
        var unit: String
        var every: Int
    }
    struct Result: Equatable {
        var at: Double
        var ok: Int
        var failed: Int
        var error: String?
    }

    var id = ""
    var name = ""
    var command = ""
    var runAs: String?
    /// A tag run: the cluster (proxy) and the query, asked again every time.
    var selector: (proxy: String, query: String)?
    var hostIds: [String] = []
    var hosts: [String] = []
    /// ms.
    var startAt: Double = 0
    var repeatRule: Repeat?
    var endAfter: Int?
    var endAt: Double?
    var retry: MXRetry?
    /// nil = not staged. `hasStaging` says whether the record had the key at all.
    var staging: MXStaging?
    var hasStaging = false
    var enabled = true
    var runs = 0
    var lastRunAt: Double?
    var lastResult: Result?
    var missed = 0
    var createdAt: Double = 0
    var nextAt: Double?

    static func == (a: MXSchedule, b: MXSchedule) -> Bool { a.json == b.json }

    init() {}

    init(json j: JSON) {
        id = j["id"].stringish ?? ""
        name = j["name"].stringish ?? ""
        command = j["command"].stringish ?? ""
        runAs = j["runAs"].string?.nilIfEmpty
        if j["selector"].object != nil {
            selector = (j["selector"]["proxy"].stringish ?? "", j["selector"]["query"].stringish ?? "")
        }
        hostIds = j["hostIds"].items.compactMap(\.stringish)
        hosts = j["hosts"].items.compactMap(\.stringish)
        startAt = j["startAt"].double ?? 0
        if j["repeat"].object != nil {
            repeatRule = Repeat(unit: j["repeat"]["unit"].stringish ?? "hours", every: Int(j["repeat"]["every"].double ?? 1))
        }
        endAfter = j["endAfter"].double.map { Int($0) }
        endAt = j["endAt"].double
        if j["retry"].object != nil { retry = MXRetry(json: j["retry"]) }
        hasStaging = j.object?.keys.contains("staging") ?? false
        if j["staging"].object != nil { staging = MXStaging(json: j["staging"]) }
        enabled = j["enabled"].bool != false
        runs = Int(j["runs"].double ?? 0)
        lastRunAt = j["lastRunAt"].double
        if j["lastResult"].object != nil {
            let r = j["lastResult"]
            lastResult = Result(at: r["at"].double ?? 0, ok: Int(r["ok"].double ?? 0), failed: Int(r["failed"].double ?? 0),
                                error: r["error"].string)
        }
        missed = Int(j["missed"].double ?? 0)
        createdAt = j["createdAt"].double ?? 0
        nextAt = j["nextAt"].double
    }

    var json: JSON {
        var j: JSON = [
            "id": .string(id), "name": .string(name), "command": .string(command), "runAs": JSON(runAs),
            "selector": selector.map { ["proxy": .string($0.proxy), "query": .string($0.query)] } ?? .null,
            "hostIds": JSON(hostIds), "hosts": JSON(hosts),
            "startAt": .number(startAt),
            "repeat": repeatRule.map { ["unit": .string($0.unit), "every": .number(Double($0.every))] } ?? .null,
            "endAfter": JSON(endAfter), "endAt": JSON(endAt),
            "enabled": .bool(enabled), "runs": .number(Double(runs)), "lastRunAt": JSON(lastRunAt),
            "lastResult": lastResult.map { r in
                var o: JSON = ["at": .number(r.at), "ok": .number(Double(r.ok)), "failed": .number(Double(r.failed))]
                if let e = r.error { o["error"] = .string(e) }
                return o
            } ?? .null,
            "missed": .number(Double(missed)), "createdAt": .number(createdAt), "nextAt": JSON(nextAt),
        ]
        if let retry { j["retry"] = retry.json }
        if hasStaging || staging != nil { j["staging"] = staging?.json ?? .null }
        return j
    }

    // MARK: When it runs (mxschedule.js)

    static let units: [String: Double] = ["minutes": 60_000, "hours": 3_600_000, "days": 86_400_000, "weeks": 604_800_000]

    private var every: Int { max(1, repeatRule?.every ?? 1) }

    /// The `i`th run of a schedule (0 is the first), as ms. Days and weeks are
    /// counted on the calendar, so "every day at 09:00" stays at 09:00 across
    /// a change of clocks; minutes and hours are counted in elapsed time.
    func occurrence(_ i: Int) -> Double {
        guard let r = repeatRule, i != 0 else { return startAt }
        if r.unit == "days" || r.unit == "weeks" {
            let d = Date(timeIntervalSince1970: startAt / 1000)
            let days = i * every * (r.unit == "weeks" ? 7 : 1)
            let out = Calendar.current.date(byAdding: .day, value: days, to: d) ?? d
            return (out.timeIntervalSince1970 * 1000).rounded()
        }
        return startAt + Double(i * every) * (MXSchedule.units[r.unit] ?? MXSchedule.units["hours"]!)
    }

    /// Whether the `i`th run is still within the schedule's end.
    private func withinEnd(_ i: Int, _ at: Double) -> Bool {
        if let n = endAfter, n != 0, i >= n { return false }
        if let e = endAt, e != 0, at > e { return false }
        return true
    }

    /// The index of the first run at or after `t`.
    private func firstIndexFrom(_ t: Double) -> Int {
        guard let r = repeatRule, t > startAt else { return 0 }
        let approx = Double(every) * (MXSchedule.units[r.unit] ?? MXSchedule.units["hours"]!)
        var i = max(0, Int(((t - startAt) / approx).rounded(.down)) - 2)
        while occurrence(i) < t { i += 1 }
        return i
    }

    /// The next run at or after `now`, or nil when there is none left. A
    /// schedule that has run `runs` times never goes back to one before its last.
    func nextRunAt(_ now: Double = nowMs()) -> Double? {
        guard repeatRule != nil else { return runs > 0 ? nil : startAt }
        let from = max(now, lastRunAt.map { $0 + 1 } ?? 0)
        let i = firstIndexFrom(from)
        let at = occurrence(i)
        return withinEnd(i, at) ? at : nil
    }

    /// How many runs fell between `from` (inclusive) and `to` (exclusive).
    func runsBetween(_ from: Double, _ to: Double) -> Int {
        if to <= from { return 0 }
        guard repeatRule != nil else { return startAt >= from && startAt < to ? 1 : 0 }
        var n = 0
        var i = firstIndexFrom(from)
        while n < 10000 {
            let at = occurrence(i)
            if at >= to || !withinEnd(i, at) { break }
            n += 1; i += 1
        }
        return n
    }

    /// The next `count` runs from `now`, for a preview.
    func upcoming(_ count: Int = 3, now: Double = nowMs()) -> [Double] {
        guard repeatRule != nil else { return startAt >= now ? [startAt] : [] }
        var out: [Double] = []
        var i = firstIndexFrom(now)
        while out.count < count {
            let at = occurrence(i)
            if !withinEnd(i, at) { break }
            out.append(at); i += 1
        }
        return out
    }

    /// "every 2 hours, 10 times" — the repeat in words.
    var describeRepeat: String {
        guard let r = repeatRule else { return "once" }
        let n = every
        let unit = n == 1 ? (r.unit.hasSuffix("s") ? String(r.unit.dropLast()) : r.unit) : r.unit
        let ev = n == 1 ? "every \(unit)" : "every \(n) \(unit)"
        if let a = endAfter, a != 0 { return ev + ", \(a) time\(a == 1 ? "" : "s")" }
        if let e = endAt, e != 0 {
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .short
            return ev + ", until " + f.string(from: Date(timeIntervalSince1970: e / 1000))
        }
        return ev
    }

    /// A time the way a person reads one: "Mon 12 Oct, 09:00".
    static func fmtWhen(_ ms: Double?) -> String {
        guard let ms, ms != 0 else { return "\u{2014}" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMHHmm")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// What a schedule runs on, in words.
    var targetText: String {
        MXSchedule.targetText(selector: selector, hosts: hosts)
    }

    static func targetText(selector: (proxy: String, query: String)?, hosts names: [String]) -> String {
        if let s = selector {
            return "hosts matching \(s.query.isEmpty ? "(everything)" : s.query)\(s.proxy.isEmpty ? "" : " on " + s.proxy)"
        }
        let more = names.count > 4 ? " +\(names.count - 4)" : ""
        return "\(names.count) host\(names.count == 1 ? "" : "s"): \(names.prefix(4).joined(separator: ", "))\(more)"
    }
}

// MARK: - The list in settings

@MainActor
enum MXSchedules {
    static var all: [MXSchedule] { Store.shared.settingJSON("mxSchedules").items.map(MXSchedule.init(json:)) }

    static func save(_ list: [MXSchedule]) {
        Store.shared.setSettingJSON("mxSchedules", .array(list.map(\.json)))
    }

    static func patch(_ id: String, _ change: (inout MXSchedule) -> Void) {
        save(all.map { var s = $0; if s.id == id { change(&s) }; return s })
    }

    /// The hosts a schedule runs on now, as run targets.
    static func targets(_ sc: MXSchedule, _ fw: FleetWindow) -> [MXTarget] {
        let hosts: [Host] = sc.selector.map { fw.hostsForSelector(MXSelector(on: true, proxy: $0.proxy, query: $0.query)) }
            ?? sc.hostIds.compactMap(FleetHooks.hostById)
        return hosts.map { host in
            let conn = ConnectionManager.shared.connections.first {
                $0.hostId == host.id && (sc.runAs == nil || $0.login == sc.runAs)
            }
            return MXTarget(hostId: host.id, host: host, connId: conn?.id, label: host.name.nilIfEmpty ?? host.alias ?? host.id)
        }
    }
}

// MARK: - The clock

/*
 * Every fifteen seconds, once for the app, so two windows do not run the
 * same schedule. Hosts are waited for after launch — a run due while the
 * inventory is still loading goes once it has loaded.
 */
@MainActor
final class MXScheduler {
    static let shared = MXScheduler()
    private let timer = Repeater()
    private var started = false
    /// runId → the schedule it was started for, and the hosts that never connected.
    private var scheduledRuns: [String: (id: String, unreachable: Int)] = [:]
    /// Schedule ids being started.
    private(set) var firing: Set<String> = []

    /// The window scheduled runs are made from: the first one.
    private var fleet: FleetWindow? {
        (WindowManager.shared.windows.first).map { $0.feature(FleetWindow.self) }
    }

    func start() {
        if started { return }
        started = true
        // Runs that fell due while ServerLife was closed are counted, not run late.
        let now = nowMs()
        let list = MXSchedules.all
        let late = { (sc: MXSchedule) in sc.enabled && (sc.nextAt ?? 0) != 0 && sc.nextAt! < now - 120_000 }
        if list.contains(where: late) {
            MXSchedules.save(list.map { sc in
                guard late(sc) else { return sc }
                var out = sc
                let missed = sc.runsBetween(sc.nextAt!, now)
                var ran = sc
                ran.lastRunAt = now - 1
                out.missed = sc.missed + missed
                out.nextAt = ran.nextRunAt(now)
                return out
            })
        }
        timer.start(every: 15) { [weak self] in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard let fw = fleet else { return }
        let t = nowMs()
        for sc in MXSchedules.all {
            guard sc.enabled, let next = sc.nextAt, next != 0, next <= t, !firing.contains(sc.id) else { continue }
            // Waits for the inventory, up to five minutes past due, before running on what there is.
            if Inventory.shared.loading && t - next < 300_000 { continue }
            if MXSchedules.targets(sc, fw).isEmpty && t - next < 300_000 { continue }
            Task { @MainActor in await self.fire(sc) }
        }
    }

    /// Run a schedule now: on its due time, or by hand.
    func fire(_ sc: MXSchedule, manual: Bool = false) async {
        guard let fw = fleet, !firing.contains(sc.id) else { return }
        firing.insert(sc.id)
        defer { firing.remove(sc.id) }
        // Moved on before the run starts, so a slow start cannot fire it twice.
        if !manual {
            var ran = sc
            ran.runs = sc.runs + 1
            ran.lastRunAt = nowMs()
            let next = ran.nextRunAt(nowMs() + 1000)
            MXSchedules.patch(sc.id) { $0.runs = ran.runs; $0.lastRunAt = ran.lastRunAt; $0.nextAt = next }
        }
        let targets = MXSchedules.targets(sc, fw)
        if targets.isEmpty {
            MXSchedules.patch(sc.id) {
                $0.lastResult = .init(at: nowMs(), ok: 0, failed: 0, error: "No hosts \u{2014} none of its hosts are listed now")
            }
            notify(sc, "did not run: none of its hosts are listed now", bad: true)
            return
        }
        let r = await fw.runMulti(sc.command, runAs: sc.runAs, label: "Scheduled: \(sc.name)", only: targets, scheduled: true,
                                  staging: sc.staging, retry: sc.retry ?? MXRetry(count: 0, delay: 10),
                                  selector: .some(sc.selector.map { MXSelector(on: true, proxy: $0.proxy, query: $0.query) }))
        if let id = r?.runId {
            scheduledRuns[id] = (sc.id, r?.unreachable ?? 0)
        } else {
            let err = r?.error
            MXSchedules.patch(sc.id) {
                $0.lastResult = .init(at: nowMs(), ok: 0, failed: targets.count, error: err ?? "Could not start")
            }
            notify(sc, "could not start: \(err ?? "no host could be connected")", bad: true)
        }
    }

    /// A scheduled run has finished: keep how it went, and say so.
    func runDone(_ view: MultiExecView) {
        guard let link = scheduledRuns.removeValue(forKey: view.id),
              let sc = MXSchedules.all.first(where: { $0.id == link.id }) else { return }
        let ok = view.results.filter { $0.status == "done" }.count
        let failed = view.results.count - ok + link.unreachable
        MXSchedules.patch(sc.id) { $0.lastResult = .init(at: nowMs(), ok: ok, failed: failed) }
        notify(sc, failed > 0 ? "\(failed) of \(ok + failed) failed" : "ok on \(ok) host\(ok == 1 ? "" : "s")", bad: failed > 0)
    }

    private func notify(_ sc: MXSchedule, _ what: String, bad: Bool) {
        StatusBus.shared.toast("Scheduled \u{201C}\(sc.name)\u{201D} \u{2014} \(what)", kind: bad ? .error : .ok, seconds: 8)
        // Said outside the window too, as nobody may be looking at it. A system
        // notification needs an app bundle; the Dock icon bounces instead.
        if !NSApp.isActive { NSApp.requestUserAttention(bad ? .criticalRequest : .informationalRequest) }
    }
}

// MARK: - The dialog

/// The fields of the schedule dialog.
@MainActor
private final class MXScheduleDraft: ObservableObject {
    @Published var name: String
    @Published var command: String
    @Published var runAs: String
    @Published var start: Date
    /// "" (once) | minutes | hours | days | weeks
    @Published var unit: String
    @Published var every: String
    /// "" (never) | after | at
    @Published var end: String
    @Published var endAfter: String
    @Published var endAt: Date
    @Published var tries: String
    @Published var gap: String
    @Published var staged: Bool
    @Published var selector: (proxy: String, query: String)?
    @Published var hostIds: [String]
    @Published var hosts: [String]

    init(_ e: MXSchedule?, command: String, runAs: String, staging: MXStaging, retry: MXRetry,
         selector: (proxy: String, query: String)?, hostIds: [String], hosts: [String]) {
        let now = nowMs()
        let startMs = e?.startAt ?? (((now + 5 * 60_000) / 300_000).rounded(.up) * 300_000)
        name = e?.name ?? FleetStore.firstLine(command.trimmed, max: 50)
        self.command = e?.command ?? command
        self.runAs = e?.runAs ?? (e == nil ? runAs : "")
        start = Date(timeIntervalSince1970: startMs / 1000)
        unit = e?.repeatRule?.unit ?? ""
        every = String(e?.repeatRule?.every ?? 1)
        end = (e?.endAfter ?? 0) != 0 ? "after" : (e?.endAt ?? 0) != 0 ? "at" : ""
        endAfter = String((e?.endAfter).flatMap { $0 == 0 ? nil : $0 } ?? 10)
        endAt = Date(timeIntervalSince1970: ((e?.endAt).flatMap { $0 == 0 ? nil : $0 } ?? startMs + 7 * 86_400_000) / 1000)
        let rt = e?.retry ?? retry
        tries = String(rt.count)
        gap = Fmt.num(rt.delay)
        let st: MXStaging? = e.map { $0.hasStaging ? $0.staging : staging } ?? staging
        staged = st != nil && st?.mode != "off"
        if let e {
            self.selector = e.selector; self.hostIds = e.hostIds; self.hosts = e.hosts
        } else {
            self.selector = selector; self.hostIds = hostIds; self.hosts = hosts
        }
    }

    /// The when-part of the schedule as typed.
    var draft: MXSchedule {
        var s = MXSchedule()
        s.startAt = (start.timeIntervalSince1970 * 1000 / 60_000).rounded(.down) * 60_000
        if !unit.isEmpty {
            s.repeatRule = .init(unit: unit, every: max(1, Int(Double(every) ?? 1)))
            if end == "after" { s.endAfter = max(1, Int(Double(endAfter) ?? 1)) }
            if end == "at" { s.endAt = (endAt.timeIntervalSince1970 * 1000 / 60_000).rounded(.down) * 60_000 }
        }
        return s
    }

    var preview: String {
        let d = draft
        let next = d.upcoming(4, now: nowMs())
        return next.isEmpty
            ? "That time has passed \u{2014} choose a later one, or a repeat."
            : "Runs \(d.describeRepeat). Next: \(next.map { MXSchedule.fmtWhen($0) }.joined(separator: " \u{00B7} "))"
    }
}

private extension Fmt {
    /// A number as JS prints it: no ".0" on a whole one.
    static func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
}

extension FleetWindow {
    /// Make a schedule, or change one.
    func openScheduleDialog(_ existing: MXSchedule? = nil, command: String = "", runAs: String = "") async {
        let w = window ?? WindowManager.shared.current()
        // The current selection is offered for a new schedule, or to replace an old one's.
        let sel: (proxy: String, query: String)? = tagSelector.on ? (tagSelector.proxy, tagSelector.query) : nil
        let picked = sel != nil ? [] : resolveTargets().filter { $0.hostId != nil }
        let fromIds = picked.compactMap(\.hostId), fromNames = picked.map(\.label)
        if existing == nil && sel == nil && picked.isEmpty {
            StatusBus.shared.toast(!resolveTargets().isEmpty
                ? "A schedule needs hosts it can find again \u{2014} tick them in the sidebar or choose by tag, not just open sessions"
                : "Select hosts in the sidebar first, or choose by tag", kind: .error)
            return
        }
        let d = MXScheduleDraft(existing, command: command, runAs: runAs, staging: staging(), retry: retrySetting(),
                                selector: sel, hostIds: fromIds, hosts: fromNames)
        let canReplace = existing != nil && (sel != nil || !fromIds.isEmpty)
        let logins = knownLogins()
        let saved: Bool? = await FleetDialog.ask(w, title: existing != nil ? "Change a scheduled run" : "Schedule a run",
                                                 width: 620) { done in
            MXScheduleForm(d: d, existing: existing != nil, logins: logins,
                           replace: canReplace ? { d.selector = sel; d.hostIds = fromIds; d.hosts = fromNames } : nil,
                           done: done)
        }
        guard saved == true else { return }

        let when = d.draft
        let cmd = d.command.trimmed
        if cmd.isEmpty { StatusBus.shared.toast("Give a command", kind: .error); return }
        var rec = when
        rec.id = existing?.id ?? "sch-" + String(Int(nowMs()), radix: 36)
        rec.name = d.name.trimmed.nilIfEmpty ?? FleetStore.firstLine(cmd, max: 50)
        rec.command = cmd
        rec.runAs = d.runAs.trimmed.nilIfEmpty
        rec.selector = d.selector
        rec.hostIds = d.selector != nil ? [] : d.hostIds
        rec.hosts = d.selector != nil ? [] : d.hosts
        rec.retry = MXRetry(count: max(0, min(10, Int(Double(d.tries) ?? 0))), delay: max(0, min(3600, Double(d.gap) ?? 0)))
        var st = staging()
        st.mode = "on"
        rec.staging = d.staged ? st : nil
        rec.hasStaging = true
        rec.enabled = existing.map(\.enabled) ?? true
        let sameStart = existing != nil && existing!.startAt == when.startAt
        rec.runs = sameStart ? existing!.runs : 0
        rec.lastRunAt = sameStart ? existing!.lastRunAt : nil
        rec.lastResult = existing?.lastResult
        rec.missed = 0
        rec.createdAt = existing.map { $0.createdAt != 0 ? $0.createdAt : nowMs() } ?? nowMs()
        rec.nextAt = rec.nextRunAt(nowMs())
        guard let next = rec.nextAt else {
            StatusBus.shared.toast("That schedule has no runs left \u{2014} choose a later start or a repeat", kind: .error)
            return
        }

        // A host marked careful is confirmed now, while someone is here to answer.
        let careful = MXSchedules.targets(rec, self).compactMap(\.host).filter(FleetHooks.careful)
        if !careful.isEmpty {
            let ok = await MiscUI.confirm(w, title: "Schedule a run on a host marked careful?",
                                          message: "\(careful.map { $0.name.nilIfEmpty ?? $0.alias ?? $0.id }.joined(separator: ", ")) \(careful.count == 1 ? "is" : "are") marked careful.",
                                          detail: "It will run without asking at \(MXSchedule.fmtWhen(next))\(rec.repeatRule != nil ? ", and " + rec.describeRepeat : "").",
                                          confirmLabel: "Schedule it", danger: true)
            if !ok { return }
        }

        MXSchedules.save(MXSchedules.all.filter { $0.id != rec.id } + [rec])
        mxView = "scheduled"
        StatusBus.shared.toast("Scheduled \u{201C}\(rec.name)\u{201D} \u{2014} first run \(MXSchedule.fmtWhen(next))", kind: .ok)
    }
}

private struct MXScheduleForm: View {
    @ObservedObject var d: MXScheduleDraft
    let existing: Bool
    let logins: [String]
    let replace: (() -> Void)?
    let done: (Bool?) -> Void

    var body: some View {
        let p = Theme.shared.p
        DialogScaffold(title: existing ? "Change a scheduled run" : "Schedule a run") {
            VStack(alignment: .leading, spacing: 10) {
                FormRow(label: "Name") { FleetField(placeholder: "Nightly disk check", text: $d.name) }
                FormRow(label: "Command") { FleetTextArea(text: $d.command, minHeight: 60) }
                FormRow(label: "Run as") {
                    HStack(spacing: 4) {
                        FleetField(placeholder: "as each host\u{2019}s usual login", text: $d.runAs, mono: true)
                        if !logins.isEmpty {
                            Menu {
                                ForEach(logins, id: \.self) { l in Button(l) { d.runAs = l } }
                            } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                }
                FormRow(label: "Hosts") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MXSchedule.targetText(selector: d.selector, hosts: d.hosts))
                            .font(.system(size: 11.5)).foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let replace {
                            Button("Use the current selection instead") { replace() }.buttonStyle(.ghostSmall)
                        }
                    }
                }
                FormRow(label: "Starts") {
                    DatePicker("", selection: $d.start, displayedComponents: [.date, .hourAndMinute]).labelsHidden().fixedSize()
                }
                FormRow(label: "Repeat") {
                    HStack(spacing: 8) {
                        FleetPicker(options: [("", "Once"), ("minutes", "Every \u{2026} minutes"), ("hours", "Every \u{2026} hours"),
                                              ("days", "Every \u{2026} days"), ("weeks", "Every \u{2026} weeks")],
                                    selection: $d.unit).frame(width: 190)
                        if !d.unit.isEmpty { FleetField(placeholder: "", text: $d.every, mono: true).frame(width: 60) }
                        Spacer()
                    }
                }
                if !d.unit.isEmpty {
                    FormRow(label: "Ends") {
                        HStack(spacing: 8) {
                            FleetPicker(options: [("", "Never"), ("after", "After a number of runs"), ("at", "On a date")],
                                        selection: $d.end).frame(width: 210)
                            if d.end == "after" { FleetField(placeholder: "", text: $d.endAfter, mono: true).frame(width: 60) }
                            if d.end == "at" {
                                DatePicker("", selection: $d.endAt, displayedComponents: [.date, .hourAndMinute]).labelsHidden().fixedSize()
                            }
                            Spacer()
                        }
                    }
                }
                FormRow(label: "Retries") {
                    HStack(spacing: 6) {
                        Text("Retry a failed host")
                        FleetField(placeholder: "", text: $d.tries, mono: true).frame(width: 50)
                        Text("more time(s),")
                        FleetField(placeholder: "", text: $d.gap, mono: true).frame(width: 60)
                        Text("seconds apart")
                        Spacer()
                    }
                    .font(.system(size: 12))
                }
                Toggle(isOn: $d.staged) {
                    Text("Run in stages as set under Advanced \u{2014} without pausing, stopping at a stage that fails")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                Text(d.preview).font(.system(size: 11.5)).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Runs while ServerLife is open, in your local time. A run due while it is closed is skipped and counted as missed, not run late.")
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        } footer: {
            Button("Cancel") { done(nil) }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
            Button(existing ? "Save" : "Schedule") { done(true) }.buttonStyle(.primary)
        }
    }
}

// MARK: - The Scheduled tab

struct MXSchedulesView: View {
    let window: WindowModel
    let fw: FleetWindow

    var body: some View {
        let p = Theme.shared.p
        let _ = Store.shared.settingJSON("mxSchedules")
        let list = MXSchedules.all.enumerated().sorted { a, b in
            let ea = a.element.enabled ? 0 : 1, eb = b.element.enabled ? 0 : 1
            if ea != eb { return ea < eb }
            let na = a.element.nextAt ?? .infinity, nb = b.element.nextAt ?? .infinity
            if na != nb { return na < nb }
            return a.offset < b.offset
        }.map(\.element)
        VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                FleetEmpty(text: "Nothing scheduled.",
                           detail: "Write a command on the Command tab, choose its hosts, and press Schedule\u{2026} to run it at a time \u{2014} once, or every so often.")
            }
            ForEach(list, id: \.id) { sc in
                let on = sc.enabled
                let last = sc.lastResult
                let when = !on ? "paused" : sc.nextAt != nil && sc.nextAt != 0 ? "next \(MXSchedule.fmtWhen(sc.nextAt))" : "finished"
                let first = sc.command.components(separatedBy: "\n").first ?? ""
                let sub: [String] = [
                    when, sc.describeRepeat, sc.targetText, sc.runAs.map { "as " + $0 } ?? "",
                    (sc.retry?.count ?? 0) > 0 ? "\(sc.retry!.count) retr\(sc.retry!.count == 1 ? "y" : "ies")" : "",
                    sc.runs > 0 ? "\(sc.runs) run\(sc.runs == 1 ? "" : "s")" : "",
                    sc.missed > 0 ? "\(sc.missed) missed while closed" : "",
                ]
                FleetRow {
                    FleetTag(text: last.map { $0.error != nil ? "!" : $0.failed > 0 ? "\($0.ok)/\($0.ok + $0.failed)" : "\($0.ok)" } ?? "\u{2014}",
                             color: last.map { $0.failed > 0 ? p.red : p.green })
                        .help(last.map { $0.error ?? "Last run \(MXSchedule.fmtWhen($0.at)): \($0.ok) ok, \($0.failed) failed" } ?? "Not run yet")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sc.name).font(.system(size: 12)).foregroundStyle(p.text).lineLimit(1)
                        Text(first + (sc.command.contains("\n") ? " \u{2026}" : ""))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                        Text(sub.filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  "))
                            .font(.system(size: 10.5)).foregroundStyle(p.muted).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Run now") { Task { @MainActor in await MXScheduler.shared.fire(sc, manual: true) } }
                        .buttonStyle(.ghostSmall).help("Run it once now; the schedule carries on as it was")
                    Button(on ? "Pause" : "Resume") {
                        MXSchedules.patch(sc.id) { s in
                            if on { s.enabled = false } else { s.enabled = true; s.nextAt = sc.nextRunAt(nowMs()); s.missed = 0 }
                        }
                    }
                    .buttonStyle(.ghostSmall)
                    Button("Edit") { Task { @MainActor in await fw.openScheduleDialog(sc) } }.buttonStyle(.ghostSmall)
                    Button("\u{00D7}") {
                        Task { @MainActor in
                            guard await MiscUI.confirm(window, title: "Delete this schedule?", message: sc.name, confirmLabel: "Delete") else { return }
                            MXSchedules.save(MXSchedules.all.filter { $0.id != sc.id })
                        }
                    }
                    .buttonStyle(.ghostSmall).help("Delete this schedule")
                }
                .opacity(on ? 1 : 0.6)
            }
        }
        .padding(.bottom, 8)
    }
}
