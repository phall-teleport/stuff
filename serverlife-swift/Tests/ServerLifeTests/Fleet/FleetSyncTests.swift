import Foundation
import Testing
@testable import ServerLife

/// The 0.39 additions: staged runs and retries, schedules (mxschedule.js),
/// macro recording (macrorecord.js), and macro order and scopes (macros.js).
@MainActor
@Suite struct FleetSyncTests {
    // MARK: Stages

    @Test func stagesAreTheCanaryThenBatches() {
        #expect(mxPlanStages(0) == [])
        #expect(mxPlanStages(1) == [1])
        #expect(mxPlanStages(12) == [1, 5, 5, 1])
        #expect(mxPlanStages(7, first: 2, batch: 3) == [2, 3, 2])
        // A first stage bigger than the run is the whole run.
        #expect(mxPlanStages(3, first: 10, batch: 5) == [3])
    }

    @Test func stagingIsAutomaticAboveTenHosts() {
        let auto = MXStaging()
        #expect(auto.stagesFor(10) == nil)
        #expect(auto.stagesFor(11) != nil)
        #expect(MXStaging(mode: "on").stagesFor(2) != nil)
        #expect(MXStaging(mode: "on").stagesFor(1) == nil)
        #expect(MXStaging(mode: "off").stagesFor(100) == nil)
        #expect(auto.planText(5) == "")
        #expect(auto.planText(12) == "Staged: 4 stages \u{2014} 1 first, then 5 at a time, pausing after each to look")
        #expect(MXStaging(mode: "on", pause: false).planText(12)
                == "Staged: 4 stages \u{2014} 1 first, then 5 at a time, stopping at a stage with a failure")
        #expect(MXStaging(mode: "on", pause: false, stopOnFail: false).planText(12)
                == "Staged: 4 stages \u{2014} 1 first, then 5 at a time")
        // Settings merge over the defaults.
        let st = MXStaging(json: ["mode": "on", "batch": 3])
        #expect(st == MXStaging(mode: "on", first: 1, batch: 3, pause: true, stopOnFail: true))
        #expect(MXStaging(json: st.json) == st)
    }

    @Test func stagesAndRetriesSurviveAYamlRoundTrip() throws {
        var o = MultiExecFile.Options()
        o.stages = .init(first: 2, batch: 4, pause: false, stopOnFail: true)
        o.retries = 3
        o.retryDelay = 30
        let text = MultiExecFile.toYaml(name: "n", command: "uptime",
                                        targets: [.init(type: "ssh", alias: "web1")], options: o, selector: nil)
        let def = try MultiExecFile.fromYaml(text)
        #expect(def.options.stages == o.stages)
        #expect(def.options.retries == 3)
        #expect(def.options.retryDelay == 30)
    }

    // MARK: Schedules

    private func sched(_ unit: String?, every: Int = 1, start: Double = 1_000_000_000_000) -> MXSchedule {
        var s = MXSchedule()
        s.startAt = start
        if let unit { s.repeatRule = .init(unit: unit, every: every) }
        return s
    }

    @Test func aOnceScheduleRunsAtItsStartAndThenNever() {
        var s = sched(nil)
        #expect(s.nextRunAt(0) == s.startAt)
        #expect(s.nextRunAt(s.startAt + 10_000) == s.startAt)   // missed, but still due
        s.runs = 1
        #expect(s.nextRunAt(0) == nil)
        #expect(s.describeRepeat == "once")
    }

    @Test func repeatingSchedulesCountInElapsedTimeOrCalendarDays() {
        let s = sched("hours", every: 2)
        #expect(s.occurrence(3) == s.startAt + 6 * 3_600_000)
        #expect(s.nextRunAt(s.startAt + 1) == s.startAt + 2 * 3_600_000)
        #expect(s.runsBetween(s.startAt, s.startAt + 10 * 3_600_000) == 5)
        #expect(s.describeRepeat == "every 2 hours")
        let d = sched("days")
        let next = Date(timeIntervalSince1970: d.occurrence(1) / 1000)
        let start = Date(timeIntervalSince1970: d.startAt / 1000)
        #expect(Calendar.current.dateComponents([.day], from: start, to: next).day == 1)
        #expect(d.describeRepeat == "every day")
    }

    @Test func aScheduleEndsAfterItsCount() {
        var s = sched("minutes", every: 5)
        s.endAfter = 3
        #expect(s.describeRepeat == "every 5 minutes, 3 times")
        #expect(s.runsBetween(0, s.startAt + 3_600_000) == 3)
        #expect(s.upcoming(10, now: 0).count == 3)
        #expect(s.nextRunAt(s.startAt + 11 * 60_000) == nil)
        // The last run is not run again.
        var t = sched("minutes")
        t.lastRunAt = t.startAt + 60_000
        #expect(t.nextRunAt(0) == t.startAt + 120_000)
    }

    @Test func aScheduleRecordRoundTrips() {
        var s = sched("weeks", every: 2)
        s.id = "s1"; s.name = "nightly"; s.command = "df -h"; s.runAs = "root"
        s.selector = (proxy: "p.example.com", query: "env=prod")
        s.retry = MXRetry(count: 2, delay: 15)
        s.staging = MXStaging(mode: "on")
        let back = MXSchedule(json: s.json)
        #expect(back == s)
        #expect(back.selector?.query == "env=prod")
        #expect(back.retry == MXRetry(count: 2, delay: 15))
    }

    // MARK: Recording

    @Test func aRecordedCommandIsReadFromItsScreenLines() {
        typealias L = MacroRecord.ScreenLine
        #expect(MacroRecord.commandFromLines([L(text: "$ ls -la   ", wrapped: false)], startX: 2) == "ls -la")
        #expect(MacroRecord.commandFromLines([L(text: "$ echo aaaa", wrapped: false), L(text: "bbbb", wrapped: true)], startX: 2)
                == "echo aaaabbbb")
        #expect(MacroRecord.commandFromLines([L(text: "$ for x in 1; do", wrapped: false), L(text: "> echo $x; done", wrapped: false)], startX: 2)
                == "for x in 1; do\necho $x; done")
        #expect(MacroRecord.commandFromLines([L(text: "(reverse-i-search)`up': uptime", wrapped: false)]) == "uptime")
    }

    @Test func secretsAreNoticedAndStepsJoined() {
        #expect(MacroRecord.looksSecret("mysql -psecret123 db"))
        #expect(MacroRecord.looksSecret("export API_KEY=abc"))
        #expect(!MacroRecord.looksSecret("ls -la"))
        #expect(MacroRecord.macroCommand(["a", " ", "b "]) == "a\nb")
        #expect(MacroRecord.macroCommand(["a", "b"], stopOnFail: true) == "a &&\nb")
    }

    // MARK: Macro order and scopes

    @Test func draggedOrderWinsAndUnplacedMacrosKeepTheirPlaceBehind() {
        let ms = ["a", "b", "c", "d"].map { Macro(id: $0, category: "C", name: $0, description: "", command: $0) }
        #expect(Macros.arranged(ms, []).map(\.id) == ["a", "b", "c", "d"])
        #expect(Macros.arranged(ms, ["c", "a"]).map(\.id) == ["c", "a", "b", "d"])
        #expect(Macros.arranged(ms, ["gone", "d"]).map(\.id) == ["d", "a", "b", "c"])
    }

    @Test func kubeAndBeamScopes() {
        #expect(Macros.runsOn(where: "kube", "kube"))
        #expect(!Macros.runsOn(where: "kube", "remote"))
        #expect(!Macros.runsOn(where: "hosts", "kube"))
        #expect(Macros.runsOn(where: "beams", "beam"))
        #expect(!Macros.runsOn(where: "beams", "remote"))
        #expect(Macros.runsOn(where: "hosts", "beam"))
        #expect(Macros.runsOn(where: nil, "local"))
        #expect(Macros.runsOn(where: "bogus", "kube"))
        #expect(Macros.pinScopesFor("beam") == ["all", "hosts", "beams"])
        #expect(Macros.pinScopesFor("kube") == ["all", "kube"])
        #expect(Macros.pinScopesFor("local") == ["all", "local"])
        #expect(Macros.pinScopesFor("remote") == ["all", "hosts"])
    }
}
