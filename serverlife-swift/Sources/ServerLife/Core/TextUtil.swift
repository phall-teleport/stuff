import Foundation

// Small text helpers more than one owner needs (csv.js, textdiff.js, util.js).

/// csv.js: RFC4180-ish CSV — a field containing a comma, quote or newline
/// gets wrapped in quotes with internal quotes doubled; everything else is
/// written bare. `columns`: `(key, label)`, `key` read from each row; a nil
/// label uses the key. Lines end in CRLF, the last one too.
func toCsv(_ rows: [[String: Any]], columns: [(key: String, label: String?)]) -> String {
    let header = columns.map { csvField($0.label ?? $0.key) }.joined(separator: ",")
    let lines = rows.map { row in columns.map { csvField(row[$0.key]) }.joined(separator: ",") }
    return ([header] + lines).joined(separator: "\r\n") + "\r\n"
}

/// The same for rows held as JSON objects.
func toCsv(_ rows: [JSON], columns: [(key: String, label: String?)]) -> String {
    toCsv(rows.map { r in
        var d: [String: Any] = [:]
        for c in columns { d[c.key] = r[c.key] }
        return d
    }, columns: columns)
}

/// `String(value)` as JavaScript writes it, then quoted when it must be.
func csvField(_ value: Any?) -> String {
    let s = jsString(value)
    guard s.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r\n" }) else { return s }
    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// `String(x)` for the values rows carry; null and undefined are empty.
private func jsString(_ value: Any?) -> String {
    guard let value else { return "" }
    switch value {
    case is NSNull: return ""
    case let s as String: return s
    case let b as Bool: return b ? "true" : "false"
    case let i as Int: return String(i)
    case let i as Int64: return String(i)
    case let d as Double:
        if d.isFinite && d == d.rounded() && abs(d) < 1e21 { return String(Int64(d)) }
        return String(d)
    case let j as JSON:
        if j.isNull { return "" }
        if let s = j.string { return s }
        if let b = j.bool { return b ? "true" : "false" }
        if let d = j.double { return jsString(d) }
        if j.array != nil { return j.array!.map { jsString($0) }.joined(separator: ",") }
        return "[object Object]"
    default: return "\(value)"
    }
}

/// One line of `diffLines`' answer.
struct DiffLine: Equatable {
    enum Kind: String { case same, add, remove }
    var type: Kind
    var line: String
}

/// textdiff.js: a plain LCS line diff for two arbitrary text blobs — used to
/// compare a Helm release's values between two revisions, where there is no
/// cluster object for `kubectl diff` and no `helm diff` plugin can be assumed.
/// Values files are small; this only needs to be correct and simple.
func diffLines(_ a: String?, _ b: String?) -> [DiffLine] {
    // An empty blob is zero lines, not one blank line — otherwise a genuinely
    // empty values.yaml diffs against a real one as "every line changed."
    let linesA = (a ?? "").isEmpty ? [] : a!.components(separatedBy: "\n")
    let linesB = (b ?? "").isEmpty ? [] : b!.components(separatedBy: "\n")
    let n = linesA.count, m = linesB.count
    // lcs[i][j] = length of the longest common subsequence of linesA[i:] and linesB[j:].
    var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = linesA[i] == linesB[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
    }
    var out: [DiffLine] = []
    var i = 0, j = 0
    while i < n && j < m {
        if linesA[i] == linesB[j] { out.append(DiffLine(type: .same, line: linesA[i])); i += 1; j += 1 }
        else if lcs[i + 1][j] >= lcs[i][j + 1] { out.append(DiffLine(type: .remove, line: linesA[i])); i += 1 }
        else { out.append(DiffLine(type: .add, line: linesB[j])); j += 1 }
    }
    while i < n { out.append(DiffLine(type: .remove, line: linesA[i])); i += 1 }
    while j < m { out.append(DiffLine(type: .add, line: linesB[j])); j += 1 }
    return out
}

extension Fmt {
    /// util.js `fmtDateTimeTz`: a moment read the way a clock on the wall
    /// reads it — 12-hour with the half of the day spelled out, and the
    /// timezone named, because "session ended" is exactly the line someone
    /// pastes into a message to someone in a different zone. "Mar 5, 3:07 PM
    /// PST"; another year adds it: "Mar 5, 2024, 3:07 PM PST". `Fmt.date`'s
    /// compact form stays as it is for the listings that use it.
    static func dateTimeTz(ms: Double?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let ms, ms != 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US")
        tf.timeZone = timeZone
        tf.dateFormat = "h:mm a zzz"
        tf.amSymbol = "AM"
        tf.pmSymbol = "PM"
        return "\(df.string(from: d)), \(tf.string(from: d))"
    }
}
