import Foundation

/*
 * Staged multi-exec: a few hosts first, a look at what happened, then the
 * rest in batches — so a command that breaks things breaks one box, not
 * forty. Off for small runs, on by itself above STAGE_ABOVE hosts ("auto"),
 * and settable to always or never under Advanced. A loaded YAML that carries
 * stages uses them for this window without changing the saved preference.
 * (dock.js `STAGING_DEFAULT`, `stagesFor`, `stageSizes`, `stagePlanText`.)
 */

/// `settings.mxStaging`: how a run is staged.
struct MXStaging: Equatable {
    /// auto | on | off
    var mode = "auto"
    var first = 1
    var batch = 5
    var pause = true
    var stopOnFail = true

    static let stageAbove = 10

    init(mode: String = "auto", first: Int = 1, batch: Int = 5, pause: Bool = true, stopOnFail: Bool = true) {
        self.mode = mode; self.first = first; self.batch = batch; self.pause = pause; self.stopOnFail = stopOnFail
    }

    /// `{ ...STAGING_DEFAULT, ...json }`.
    init(json: JSON, base: MXStaging = MXStaging()) {
        self = base
        if let m = json["mode"].string { mode = m }
        if let n = json["first"].double { first = Int(n) }
        if let n = json["batch"].double { batch = Int(n) }
        if let b = json["pause"].bool { pause = b }
        if let b = json["stopOnFail"].bool { stopOnFail = b }
    }

    var json: JSON {
        ["mode": .string(mode), "first": .number(Double(first)), "batch": .number(Double(batch)),
         "pause": .bool(pause), "stopOnFail": .bool(stopOnFail)]
    }

    /// The stages option for a run on `n` hosts, or nil when it runs all at once.
    func stagesFor(_ n: Int) -> MultiExecService.Stages? {
        let on = mode == "on" ? n > 1 : mode == "auto" ? n > MXStaging.stageAbove : false
        return on ? .init(first: first, batch: batch, pause: pause, stopOnFail: stopOnFail) : nil
    }

    /// "Staged: 4 stages — 1 first, then 5 at a time, pausing after each to look"
    func planText(_ n: Int) -> String {
        guard let st = stagesFor(n) else { return "" }
        let sizes = mxPlanStages(n, first: st.first, batch: st.batch)
        return "Staged: \(sizes.count) stages \u{2014} \(sizes.first ?? 0) first, then \(st.batch) at a time"
            + (st.pause ? ", pausing after each to look" : st.stopOnFail ? ", stopping at a stage with a failure" : "")
    }
}

/// `settings.mxRetry`: retrying a host that fails — how many more tries, and how far apart.
struct MXRetry: Equatable {
    var count = 0
    /// Seconds.
    var delay: Double = 10

    init(count: Int = 0, delay: Double = 10) { self.count = count; self.delay = delay }

    init(json: JSON, base: MXRetry = MXRetry()) {
        self = base
        if let n = json["count"].double { count = Int(n) }
        if let n = json["delay"].double { delay = n }
    }

    var json: JSON { ["count": .number(Double(count)), "delay": .number(delay)] }
}

extension Store {
    /// `{ ...STAGING_DEFAULT, ...settings.mxStaging }`.
    var mxStaging: MXStaging {
        get { MXStaging(json: settingJSON("mxStaging")) }
        set { setSettingJSON("mxStaging", newValue.json) }
    }

    /// `{ ...RETRY_DEFAULT, ...settings.mxRetry }`.
    var mxRetry: MXRetry {
        get { MXRetry(json: settingJSON("mxRetry")) }
        set { setSettingJSON("mxRetry", newValue.json) }
    }
}
