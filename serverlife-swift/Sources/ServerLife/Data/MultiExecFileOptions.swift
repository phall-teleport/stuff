import Foundation

/// The 0.17 additions to multiexecfile.js's `options` block — staged runs and
/// retries — as pure helpers over `YAMLValue`, for `MultiExecFile`
/// (Fleet/Formats, owned by fleet) to fold into `toYaml` / `fromYaml`.
///
/// Written after `stopOnError`, in this order:
///
/// ```yaml
/// options:
///   stages: { first: 1, batch: 5, pause: true, stopOnFail: true }   # omitted when not staged
///   retries: 0
///   retryDelaySeconds: 10
/// ```
enum MXFileOptions {
    /// Staged runs keep their stages: first so many, then batches of so many.
    struct Stages: Equatable {
        var first: Int = 1
        var batch: Int = 5
        /// Wait for a go-ahead between stages.
        var pause = true
        /// Stop at the end of a stage that had a failure.
        var stopOnFail = true
    }

    struct Extras: Equatable {
        var stages: Stages?
        /// A host that fails is tried this many more times …
        var retries: Int = 0
        /// … so many seconds apart.
        var retryDelaySeconds: Double = 10
    }

    /// `toYaml`'s entries, to append to the options map after `stopOnError`.
    /// A `nil` stages is written as null, which `MultiExecFile.stripNulls`
    /// removes, as js-yaml's output does after the original's own strip.
    static func yamlEntries(_ x: Extras) -> [(String, YAMLValue)] {
        let stages: YAMLValue = x.stages.map {
            .map([("first", .int($0.first)), ("batch", .int($0.batch)),
                  ("pause", .bool($0.pause)), ("stopOnFail", .bool($0.stopOnFail))])
        } ?? .null
        return [("stages", stages), ("retries", .int(x.retries)), ("retryDelaySeconds", number(x.retryDelaySeconds))]
    }

    /// `fromYaml`: read them back from the `options` mapping, with the
    /// original's defaults and clamps (retries 0…10, whole; delay 0…3600 s).
    static func parse(options o: YAMLValue) -> Extras {
        var x = Extras()
        let st = o["stages"]
        if st.truthy {
            x.stages = Stages(first: orDefault(st["first"].jsNumber, 1),
                              batch: orDefault(st["batch"].jsNumber, 5),
                              pause: st["pause"] != .bool(false),
                              stopOnFail: st["stopOnFail"] != .bool(false))
        }
        // `Math.max(0, Math.min(10, Math.floor(Number(r)) || 0))`
        let r = o["retries"].jsNumber.rounded(.down)
        x.retries = r.isNaN ? 0 : Int(max(0, min(10, r)))
        // `Math.max(0, Math.min(3600, Number(d ?? 10)))` — a missing or null
        // delay is 10; a non-number would be NaN there (and act as no wait).
        let dv = o["retryDelaySeconds"]
        let d = dv.isNull ? 10 : dv.jsNumber
        x.retryDelaySeconds = d.isNaN ? 0 : max(0, min(3600, d))
        return x
    }

    /// `Number(x) || n`, as a whole number.
    private static func orDefault(_ d: Double, _ n: Int) -> Int {
        d.isFinite && d != 0 ? Int(d) : n
    }

    private static func number(_ d: Double) -> YAMLValue {
        d == d.rounded() && abs(d) < 9e15 ? .int(Int(d)) : .double(d)
    }
}
