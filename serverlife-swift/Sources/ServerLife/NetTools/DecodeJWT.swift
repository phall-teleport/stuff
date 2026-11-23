import Foundation

// decoders.js — URL encode/decode and the JWT reader.

struct URLDecodeResult: Equatable {
    struct Parts: Equatable { var proto: String; var username: String?; var host: String; var port: String?; var path: String; var fragment: String? }
    struct Param: Equatable { var key: String; var value: String }
    var encoded: String
    var encodedUrl: String
    var decoded: String?
    var parts: Parts?
    var query: [Param]?
}

struct JWTResult {
    struct Field: Equatable { var key, name: String; var time: String?; var list: [String]?; var value: String? }
    struct Trait: Equatable { var name: String; var values: [String] }
    struct Claims { var fields: [Field] = []; var roles: [String] = []; var traits: [Trait] = [] }
    var header: JSON
    var payload: JSON
    var times: [String: String]
    var state: String
    var kind: String
    var claims: Claims
    var raw: (header: String, payload: String, signature: String)
    var expiresIn: Int?
    var signature: (alg: String?, bytes: Int, verified: Bool)
}

/// JS `String(x)` / `JSON.stringify` for the shapes a token carries.
func ntJSString(_ j: JSON) -> String {
    switch j {
    case .string(let s): return s
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number: return j.jsText()
    case .array(let a): return a.map { $0.isNull ? "" : ntJSString($0) }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

/// `new Date(ms).toISOString()`.
func ntISO(ms: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

extension NTDecode {
    // MARK: URL

    static let uriUnreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    static let uriReserved = uriUnreserved.union(CharacterSet(charactersIn: ";,/?:@&=+$#"))

    static func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: uriUnreserved) ?? s
    }
    static func encodeURI(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: uriReserved) ?? s
    }
    /// `decodeURIComponent`: nil where it would throw (a stray %).
    static func decodeURIComponent(_ s: String) -> String? {
        if !s.contains("%") { return s }
        return s.removingPercentEncoding
    }

    /// Both directions at once, so there is nothing to choose: what the text
    /// is encoded, what it is decoded (when it decodes), and — for a whole URL
    /// — its parts with the query taken apart.
    static func url(_ input: String) throws -> URLDecodeResult {
        guard !input.isEmpty else { throw AppError("Paste some text or a URL.") }
        var decoded: String? = nil
        if let d = decodeURIComponent(input.replacingOccurrences(of: "+", with: " ")), d != input { decoded = d }
        var out = URLDecodeResult(encoded: encodeURIComponent(input), encodedUrl: encodeURI(input), decoded: decoded)
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // `new URL()` wants a scheme; URLComponents is laxer, so ask for one.
        if t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil,
           let u = URLComponents(string: t), let scheme = u.scheme {
            let dec: (String?) -> String? = { $0.map { decodeURIComponent($0) ?? $0 } }
            out.parts = .init(
                proto: scheme.lowercased(),
                username: (u.percentEncodedUser?.isEmpty == false) ? dec(u.percentEncodedUser) : nil,
                host: (u.host ?? "").lowercased(),
                port: u.port.map(String.init),
                path: dec(u.percentEncodedPath.isEmpty && u.host != nil ? "/" : u.percentEncodedPath) ?? "",
                fragment: (u.percentEncodedFragment?.isEmpty == false) ? dec(u.percentEncodedFragment) : nil)
            out.query = searchParams(u.percentEncodedQuery ?? "")
        }
        return out
    }

    /// URLSearchParams: split on &, then =, + is a space, percent-decoded.
    static func searchParams(_ q: String) -> [URLDecodeResult.Param] {
        q.split(separator: "&").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let d: (String) -> String = { s in
                let p = s.replacingOccurrences(of: "+", with: " ")
                return p.removingPercentEncoding ?? p
            }
            return .init(key: d(kv[0]), value: kv.count > 1 ? d(kv[1]) : "")
        }
    }

    // MARK: JWT

    static let timeClaims = ["exp", "nbf", "iat", "auth_time"]

    /// Registered claim names, spelled out.
    static let claimNames: [String: String] = [
        "iss": "Issuer", "sub": "Subject", "aud": "Audience", "exp": "Expires", "nbf": "Not before",
        "iat": "Issued", "jti": "Token ID", "azp": "Authorised party", "auth_time": "Authenticated",
        "username": "User", "email": "Email", "name": "Name", "scope": "Scope", "scp": "Scope",
    ]

    static func base64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
        t = t.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" }
        if t.count % 4 == 1 { t.removeLast() }   // Buffer drops a dangling 6 bits
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func b64urlJson(_ part: String, _ what: String) throws -> JSON {
        guard let d = base64url(part), let j = try? JSON.parse(d) else {
            throw AppError("The \(what) is not base64url-encoded JSON.")
        }
        return j
    }

    /// A JWT's header and claims, its times in words, and what it looks like
    /// it is. The signature is reported, not verified: that needs the issuer's
    /// key, which a pasted token does not come with.
    static func jwt(_ input: String, now: Double = Date().timeIntervalSince1970 * 1000) throws -> JWTResult {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^Bearer\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        let parts = token.components(separatedBy: ".")
        if parts.count == 5 { throw AppError("That is an encrypted JWT (JWE) — it cannot be read without the key.") }
        guard parts.count == 3 else { throw AppError("A JWT has three parts separated by dots.") }
        let header = try b64urlJson(parts[0], "header")
        let payload = try b64urlJson(parts[1], "payload")
        var times: [String: String] = [:]
        for k in timeClaims { if case .number(let n) = payload[k] { times[k] = ntISO(ms: n * 1000) } }
        var state = "valid"
        if case .number(let exp) = payload["exp"], exp * 1000 <= now { state = "expired" }
        else if case .number(let nbf) = payload["nbf"], nbf * 1000 > now { state = "not yet valid" }
        let sub = payload["sub"].truthy ? ntJSString(payload["sub"]) : ""
        let kind = sub.hasPrefix("spiffe://") ? "JWT-SVID (SPIFFE)"
            : (payload["roles"].truthy || payload["traits"].truthy) && payload["username"].truthy ? "Teleport application token"
            : ""
        var expiresIn: Int? = nil
        if case .number(let exp) = payload["exp"] { expiresIn = Int((exp - now / 1000).rounded(.toNearestOrAwayFromZero)) }
        return JWTResult(
            header: header, payload: payload, times: times, state: state, kind: kind,
            claims: readableClaims(payload), raw: (parts[0], parts[1], parts[2]), expiresIn: expiresIn,
            signature: (header["alg"].truthy ? ntJSString(header["alg"]) : nil, base64url(parts[2])?.count ?? 0, false))
    }

    /// The claims in reading order — who issued it and to whom first, then
    /// times, then everything else. Roles and traits, which Teleport puts in
    /// its application tokens, come out separately as for an SSH certificate.
    static func readableClaims(_ payload: JSON) -> JWTResult.Claims {
        let order = ["iss", "sub", "aud", "username", "email", "name", "iat", "nbf", "exp", "auth_time", "jti"]
        let obj = payload.entries
        let keys = order.filter { obj[$0] != nil } + obj.keys.filter { !order.contains($0) }.sorted()
        var out = JWTResult.Claims()
        for k in keys {
            let v = obj[k] ?? .null
            if k == "roles", let a = v.array { out.roles = a.map(ntJSString); continue }
            if k == "traits", let o = v.object {
                out.traits = o.map { n, vals in
                    JWTResult.Trait(name: n, values: (vals.array ?? [vals]).filter { $0 != .string("") && !$0.isNull }.map(ntJSString))
                }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                continue
            }
            var time: String? = nil
            if timeClaims.contains(k), case .number(let n) = v { time = ntISO(ms: n * 1000) }
            let list = v.array.map { $0.map { x -> String in
                if case .object = x { return x.jsText() }
                if case .array = x { return x.jsText() }
                return ntJSString(x)
            } }
            let value: String? = v.array != nil ? nil : (v.object != nil ? v.jsText() : ntJSString(v))
            out.fields.append(.init(key: k, name: claimNames[k] ?? k, time: time, list: list, value: value))
        }
        return out
    }
}
