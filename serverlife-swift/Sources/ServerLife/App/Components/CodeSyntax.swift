import Foundation

/// What a span of code *is*, for colouring — the highlight tags cmtheme.js
/// styles. Colours come from the palette (`CodeEditor` maps them), so they
/// are right in the dark and light themes.
enum CodeToken: Equatable {
    /// A YAML mapping's key, an ssh_config option name — accent.
    case key
    /// Host and Match lines, YAML directives — purple, semibold.
    case keyword
    /// Quoted text, a directive's value, an ssh_config value — green.
    case string
    /// The | or > that opens a block of text, such as a shell script — amber.
    case special
    /// Comments — muted, italic.
    case comment
    /// Anchors, aliases and tags — purple.
    case label
    /// `- : , [ ] { } ?` — dim.
    case punctuation
    /// `---` / `...` — muted.
    case meta
    /// An ssh option ssh does not know — usually a typo. Red, underlined.
    case invalid
}

/// The languages the shared editor colours. `.text` is a plain,
/// highlight-free editor shell (yamleditor.js `lang: 'text'`, for
/// `kubectl describe` output, which is not YAML).
enum CodeLanguage: String { case yaml, sshConfig = "ssh_config", text }

struct CodeSpan: Equatable {
    /// UTF-16 offsets, as NSString / JavaScript count them.
    var range: NSRange
    var token: CodeToken
}

enum CodeSyntax {
    static func spans(_ text: String, _ language: CodeLanguage) -> [CodeSpan] {
        switch language {
        case .yaml: return yaml(text)
        case .sshConfig: return sshConfig(text)
        case .text: return []
        }
    }

    // MARK: ssh_config (sshconfigeditor.js's StreamLanguage, token for token)

    /// Lines that start a block.
    private static let block: Set<String> = ["host", "match"]

    static func sshConfig(_ text: String) -> [CodeSpan] {
        var out: [CodeSpan] = []
        let s = Array(text.utf16)
        var lineStart = 0
        while lineStart <= s.count {
            var lineEnd = lineStart
            while lineEnd < s.count && s[lineEnd] != 10 { lineEnd += 1 }
            var i = lineStart
            var atValue = false
            func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }
            func isAlpha(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
            func isAlnum(_ c: UInt16) -> Bool { isAlpha(c) || (c >= 48 && c <= 57) }
            func emit(_ from: Int, _ to: Int, _ t: CodeToken) {
                if to > from { out.append(CodeSpan(range: NSRange(location: from, length: to - from), token: t)) }
            }
            while i < lineEnd {
                if isSpace(s[i]) { while i < lineEnd && isSpace(s[i]) { i += 1 }; continue }
                if s[i] == 35 /* # */ { emit(i, lineEnd, .comment); i = lineEnd; break }
                if !atValue {
                    if isAlpha(s[i]) {
                        let from = i
                        while i < lineEnd && isAlnum(s[i]) { i += 1 }
                        let name = String(utf16CodeUnits: Array(s[from..<i]), count: i - from).lowercased()
                        atValue = true
                        // The `=` some people write between name and value is just a separator.
                        var j = i
                        while j < lineEnd && isSpace(s[j]) { j += 1 }
                        if j < lineEnd && s[j] == 61 /* = */ { i = j + 1 }
                        let t: CodeToken = block.contains(name) ? .keyword
                            : (SSHConfigSyntax.knownOptions.contains(name) ? .key : .invalid)
                        emit(from, i, t)
                        continue
                    }
                    emit(i, i + 1, .invalid); i += 1
                    continue
                }
                if s[i] == 34 /* " */ {
                    let from = i
                    i += 1
                    while i < lineEnd && s[i] != 34 { i += 1 }
                    if i < lineEnd { i += 1 }
                    emit(from, i, .string)
                    continue
                }
                // A Host line's patterns, a negation, and an option's value.
                let from = i
                if s[i] == 33 /* ! */ { i += 1 }
                while i < lineEnd && !isSpace(s[i]) && s[i] != 35 { i += 1 }
                if i > from + (s[from] == 33 ? 1 : 0) { emit(from, i, .string) } else { i = from + 1 }
            }
            lineStart = lineEnd + 1
        }
        return out
    }

    // MARK: YAML (the tags @codemirror/lang-yaml gives, line by line)

    static func yaml(_ text: String) -> [CodeSpan] {
        var out: [CodeSpan] = []
        let s = Array(text.utf16)
        func emit(_ from: Int, _ to: Int, _ t: CodeToken) {
            if to > from { out.append(CodeSpan(range: NSRange(location: from, length: to - from), token: t)) }
        }
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }
        /// Inside a `|` / `>` block: lines indented deeper than this are its text.
        var blockIndent: Int? = nil
        var lineStart = 0
        while lineStart <= s.count {
            var lineEnd = lineStart
            while lineEnd < s.count && s[lineEnd] != 10 { lineEnd += 1 }
            defer { lineStart = lineEnd + 1 }
            var i = lineStart
            while i < lineEnd && (s[i] == 32 || s[i] == 9) { i += 1 }
            let indent = i - lineStart
            let blank = i >= lineEnd || (i == lineEnd - 1 && s[i] == 13)
            if let b = blockIndent {
                let marker = indent == 0 && lineEnd - i >= 3
                    && (Array(s[i..<(i + 3)]) == [45, 45, 45] || Array(s[i..<(i + 3)]) == [46, 46, 46])
                if !marker && (blank || indent > b) { continue }
                blockIndent = nil
            }
            if blank { continue }

            // Directives and document markers, at the start of a line only.
            if indent == 0 && s[i] == 37 /* % */ {
                var j = i
                while j < lineEnd && !isSpace(s[j]) { j += 1 }
                emit(i, j, .keyword)
                var k = j
                while k < lineEnd && isSpace(s[k]) { k += 1 }
                let c = commentStart(s, k, lineEnd)
                emit(k, trimEnd(s, k, c), .string)
                if c < lineEnd { emit(c, lineEnd, .comment) }
                continue
            }
            if indent == 0 && lineEnd - i >= 3 {
                let m = Array(s[i..<(i + 3)])
                let dash: [UInt16] = [45, 45, 45], dots: [UInt16] = [46, 46, 46]
                if (m == dash || m == dots) && (i + 3 == lineEnd || isSpace(s[i + 3])) {
                    emit(i, i + 3, .meta)
                    i += 3
                    while i < lineEnd && isSpace(s[i]) { i += 1 }
                    if i < lineEnd && s[i] == 35 { emit(i, lineEnd, .comment); continue }
                    if i >= lineEnd { continue }
                    // `--- |` and `--- value` carry on as a value.
                    if let b = value(s, i, lineEnd, &out, indent: -1) { blockIndent = b }
                    continue
                }
            }
            if s[i] == 35 { emit(i, lineEnd, .comment); continue }

            // Sequence markers and explicit-key markers, any number of them.
            var keyIndent = indent
            while i < lineEnd, (s[i] == 45 || s[i] == 63), i + 1 == lineEnd || isSpace(s[i + 1]) {
                emit(i, i + 1, .punctuation)
                i += 1
                while i < lineEnd && isSpace(s[i]) { i += 1 }
                keyIndent = i - lineStart
            }
            if i >= lineEnd { continue }
            if s[i] == 35 { emit(i, lineEnd, .comment); continue }

            // `key:` — plain or quoted — then its value.
            if let (kEnd, colon) = keyAt(s, i, lineEnd) {
                emit(i, kEnd, .key)
                emit(colon, colon + 1, .punctuation)
                var v = colon + 1
                while v < lineEnd && isSpace(s[v]) { v += 1 }
                if v < lineEnd, let b = value(s, v, lineEnd, &out, indent: keyIndent) { blockIndent = b }
                continue
            }
            if let b = value(s, i, lineEnd, &out, indent: keyIndent) { blockIndent = b }
        }
        return out
    }

    /// Where a `#` comment starts in `s[from..<end]` (`end` when none): a `#`
    /// at the start or after whitespace, outside quotes.
    private static func commentStart(_ s: [UInt16], _ from: Int, _ end: Int) -> Int {
        var i = from
        var quote: UInt16 = 0
        while i < end {
            let c = s[i]
            if quote != 0 {
                if c == quote {
                    if quote == 39, i + 1 < end, s[i + 1] == 39 { i += 2; continue }
                    quote = 0
                } else if quote == 34 && c == 92 { i += 1 }
            } else if (c == 34 || c == 39) && (i == from || s[i - 1] == 32 || s[i - 1] == 9 || "[{,:".utf16.contains(s[i - 1])) {
                quote = c
            } else if c == 35 && (i == from || s[i - 1] == 32 || s[i - 1] == 9) {
                return i
            }
            i += 1
        }
        return end
    }

    private static func trimEnd(_ s: [UInt16], _ from: Int, _ to: Int) -> Int {
        var t = to
        while t > from && (s[t - 1] == 32 || s[t - 1] == 9 || s[t - 1] == 13) { t -= 1 }
        return t
    }

    /// A mapping key at `i`: its end and the colon's offset.
    private static func keyAt(_ s: [UInt16], _ i: Int, _ end: Int) -> (Int, Int)? {
        func colonAfter(_ j: Int) -> Int? {
            var k = j
            while k < end && (s[k] == 32 || s[k] == 9) { k += 1 }
            guard k < end, s[k] == 58 else { return nil }
            return (k + 1 == end || s[k + 1] == 32 || s[k + 1] == 9 || s[k + 1] == 13) ? k : nil
        }
        let c = s[i]
        if c == 34 || c == 39 {
            var j = i + 1
            while j < end {
                if s[j] == c {
                    if c == 39, j + 1 < end, s[j + 1] == 39 { j += 2; continue }
                    break
                }
                if c == 34 && s[j] == 92 { j += 1 }
                j += 1
            }
            guard j < end else { return nil }
            return colonAfter(j + 1).map { (j + 1, $0) }
        }
        // Flow collections, anchors, aliases, tags and block indicators are values.
        if "[{&*!|>%@`".utf16.contains(c) { return nil }
        var j = i
        while j < end {
            if s[j] == 58, j + 1 == end || s[j + 1] == 32 || s[j + 1] == 9 || s[j + 1] == 13 {
                let kEnd = trimEnd(s, i, j)
                return kEnd > i ? (kEnd, j) : nil
            }
            if s[j] == 35, j > i, s[j - 1] == 32 || s[j - 1] == 9 { return nil }
            j += 1
        }
        return nil
    }

    /// Colours a value from `i` to the end of the line. Returns the indent a
    /// following block of text must exceed when the value opens one (`|`, `>`).
    private static func value(_ s: [UInt16], _ start: Int, _ end: Int, _ out: inout [CodeSpan], indent: Int) -> Int? {
        func emit(_ from: Int, _ to: Int, _ t: CodeToken) {
            if to > from { out.append(CodeSpan(range: NSRange(location: from, length: to - from), token: t)) }
        }
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }
        var i = start
        let cEnd = commentStart(s, start, end)
        var opensBlock = false
        var depth = 0
        while i < cEnd {
            let c = s[i]
            if isSpace(c) { i += 1; continue }
            // Anchors, aliases, tags.
            if (c == 38 || c == 42 || c == 33) && depth >= 0 {
                var j = i + 1
                while j < cEnd && !isSpace(s[j]) && !(depth > 0 && ",[]{}".utf16.contains(s[j])) { j += 1 }
                emit(i, j, .label)
                i = j
                continue
            }
            if depth == 0 && (c == 124 || c == 62) /* | > */ {
                var j = i + 1
                while j < cEnd && (s[j] == 45 || s[j] == 43 || (s[j] >= 49 && s[j] <= 57)) { j += 1 }
                if trimEnd(s, j, cEnd) == j {
                    emit(i, j, .special)
                    opensBlock = true
                    i = cEnd
                    break
                }
            }
            if c == 34 || c == 39 {
                var j = i + 1
                while j < cEnd {
                    if s[j] == c {
                        if c == 39, j + 1 < cEnd, s[j + 1] == 39 { j += 2; continue }
                        break
                    }
                    if c == 34 && s[j] == 92 { j += 1 }
                    j += 1
                }
                j = min(j + 1, cEnd)
                emit(i, j, .string)
                i = j
                // A quoted key inside a flow mapping.
                if depth > 0, i < cEnd, s[i] == 58 { emit(i, i + 1, .punctuation); i += 1 }
                continue
            }
            if c == 91 || c == 93 || c == 123 || c == 125 || (depth > 0 && c == 44) {
                emit(i, i + 1, .punctuation)
                if c == 91 || c == 123 { depth += 1 } else if c == 93 || c == 125 { depth = max(0, depth - 1) }
                i += 1
                continue
            }
            // A plain scalar: text-coloured, so nothing to emit — except a
            // flow mapping's key.
            var j = i
            while j < cEnd {
                if depth > 0 && ",[]{}".utf16.contains(s[j]) { break }
                if depth > 0 && s[j] == 58 && (j + 1 == cEnd || isSpace(s[j + 1]) || ",]}".utf16.contains(s[j + 1])) { break }
                if depth == 0 { j = cEnd; break }
                j += 1
            }
            if depth > 0 && j < cEnd && s[j] == 58 {
                emit(i, trimEnd(s, i, j), .key)
                emit(j, j + 1, .punctuation)
                j += 1
            }
            i = max(j, i + 1)
        }
        if cEnd < end { emit(cEnd, end, .comment) }
        return opensBlock ? indent : nil
    }
}

/// ssh_config's directives — main/sshoptions.js `KNOWN_SSH_OPTIONS`, the list
/// the app checks "extra ssh options" against, so the editor and that check
/// never disagree. Lower-case.
enum SSHConfigSyntax {
    static let knownOptions: Set<String> = [
        "addkeystoagent", "addressfamily", "batchmode", "bindaddress", "bindinterface",
        "canonicaldomains", "canonicalizefallbacklocal", "canonicalizehostname",
        "canonicalizemaxdots", "canonicalizepermittedcnames", "casignaturealgorithms",
        "certificatefile", "channeltimeout", "checkhostip", "ciphers", "clearallforwardings",
        "compression", "connectionattempts", "connecttimeout", "controlmaster", "controlpath",
        "controlpersist", "dynamicforward", "enableescapecommandline", "enablesshkeysign",
        "escapechar", "exitonforwardfailure", "fingerprinthash", "forkafterauthentication",
        "forwardagent", "forwardx11", "forwardx11timeout", "forwardx11trusted", "gatewayports",
        "globalknownhostsfile", "gssapiauthentication", "gssapidelegatecredentials",
        "hashknownhosts", "hostbasedacceptedalgorithms", "hostbasedauthentication",
        "hostkeyalgorithms", "hostkeyalias", "hostname", "identitiesonly", "identityagent",
        "identityfile", "ignoreunknown", "include", "ipqos", "kbdinteractiveauthentication",
        "kbdinteractivedevices", "kexalgorithms", "knownhostscommand", "localcommand",
        "localforward", "loglevel", "logverbose", "macs", "match", "nohostauthenticationforlocalhost",
        "numberofpasswordprompts", "obscurekeystroketiming", "passwordauthentication",
        "permitlocalcommand", "permitremoteopen", "pkcs11provider", "port",
        "preferredauthentications", "proxycommand", "proxyjump", "proxyusefdpass",
        "pubkeyacceptedalgorithms", "pubkeyacceptedkeytypes", "pubkeyauthentication",
        "rekeylimit", "remotecommand", "remoteforward", "requesttty", "requiredrsasize",
        "revokedhostkeys", "securitykeyprovider", "sendenv", "serveralivecountmax",
        "serveraliveinterval", "sessiontype", "setenv", "stdinnull", "streamlocalbindmask",
        "streamlocalbindunlink", "stricthostkeychecking", "syslogfacility", "tcpkeepalive",
        "tunnel", "tunneldevice", "updatehostkeys", "user", "userknownhostsfile",
        "verifyhostkeydns", "visualhostkey", "xauthlocation",
    ]
}
