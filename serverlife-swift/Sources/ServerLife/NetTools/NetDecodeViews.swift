import SwiftUI

// nettools.js renderCidr, renderUrl, renderSshCert, renderJwt, renderSvid and
// rawFor: the decoders' results, readable first.

struct CIDRView: View {
    let r: CIDRResult
    private func big(_ v: String) -> String {
        guard let d = Double(v) else { return v }
        return v.count > 15 ? "2^\(Int(log2(d).rounded()))" : NumberFormatter.localizedString(from: NSNumber(value: d), number: .decimal)
    }
    var body: some View {
        NTRawToggle(raw: r.json.jsText(indent: 2)) {
        VStack(alignment: .leading, spacing: 0) {
        if let c = r.check {
            HStack(spacing: 4) {
                NTBadge(text: c.inside ? "inside" : "outside", kind: c.inside ? "ok" : "bad")
                Text(" \(c.address) is \(c.inside ? "" : "not ")in \(r.cidr)").font(.system(size: 12)).textSelection(.enabled)
            }.padding(.bottom, 10)
        }
        if r.hostBitsSet {
            NTHint(text: "\(r.input) has host bits set; the network it belongs to is \(r.cidr).").padding(.bottom, 8)
        }
        NTSection(title: "IPv\(r.family) subnet", rows: CIDRView.rows(r, big: big))
        }
        }
    }
    static func rows(_ r: CIDRResult, big: (String) -> String = { $0 }) -> [(String, String?)] {
        [("CIDR", r.cidr), ("Network", r.network), ("Netmask", r.netmask), ("Wildcard (ACL) mask", r.wildcard),
         ("Broadcast", r.broadcast), ("Usable range", "\(r.first) – \(r.last)"), ("Last address", r.lastAddress),
         ("Addresses", big(r.total)), ("Usable hosts", big(r.usable)), ("Kind", r.kind)]
    }
}

struct URLDecodeView: View {
    let r: URLDecodeResult
    var file: String? = nil
    @ViewBuilder private func copyable(_ label: String, _ v: String?) -> some View {
        if let v, !v.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    NTHead(text: label)
                    Button("Copy") { Clipboard.write(v); StatusBus.shared.show("\(label) copied") }.buttonStyle(.ghostSmall)
                }
                NTPre(text: v)
            }.padding(.bottom, 13)
        }
    }
    var body: some View {
        NTRawToggle(raw: r.json.jsText(indent: 2)) { VStack(alignment: .leading, spacing: 0) { readable } }
    }
    @ViewBuilder private var readable: some View {
        NTFileCard(file: file)
        copyable("Decoded", r.decoded)
        copyable("Encoded (a value in a query string)", r.encoded)
        copyable("Encoded (a whole URL)", r.encodedUrl != r.encoded ? r.encodedUrl : nil)
        if let p = r.parts {
            NTSection(title: "URL", rows: [("Scheme", p.proto), ("User", p.username), ("Host", p.host),
                                           ("Port", p.port), ("Path", p.path), ("Fragment", p.fragment)])
        }
        if let q = r.query, !q.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                NTHead(text: "Query")
                NTKV(rows: q.map { ($0.key, Optional($0.value)) })
            }.padding(.bottom, 13)
        }
    }
}

/// `traitRows(traits)`: the busiest last.
private func ntTraitRows(_ traits: [(name: String, values: [String])]) -> [(String, NTVal)] {
    traits.sorted { $0.values.count != $1.values.count ? $0.values.count < $1.values.count : $0.name < $1.name }
        .map { ($0.name, NTVal.tags($0.values, max: 8)) }
}

struct SSHCertView: View {
    let r: SSHCertResult
    let file: String?
    var body: some View {
        let x = r.readable
        let cluster = x.teleport.first { $0.name == "Cluster" }?.value
        let logins = r.principals.filter { !$0.hasPrefix("-teleport") }
        let hidden = r.principals.filter { $0.hasPrefix("-teleport") }
        let who = r.type == "host"
            ? "Host certificate for \(logins.isEmpty ? r.keyId : logins.joined(separator: ", "))"
            : "User certificate for \(r.keyId.isEmpty ? "an unnamed key" : r.keyId)\(cluster.map { " on \($0)" } ?? "")"
        NTRawToggle(raw: r.raw) {
            VStack(alignment: .leading, spacing: 0) {
                NTHeadline(text: who, badges: [NTWhen.stateTag(r.state, r.expiresIn)] + (r.teleport ? [("Teleport", "name")] : []))
                NTFileCard(file: file)
                NTCmdBlock(command: NetPreview.sshCertCommand(file))
                NTCard(title: r.type == "host" ? "Names it is valid for" : "Logins it allows") {
                    if r.principals.isEmpty { Text("Any login — the certificate names none").font(.system(size: 12)) }
                    else { NTTags(values: logins, max: 16) }
                    if !hidden.isEmpty {
                        Text("Also \(hidden.joined(separator: ", ")) — Teleport's own, not a login")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.shared.p.muted).padding(.top, 4)
                    }
                }
                NTCard(title: "Validity") { NTRows(rows: [("From", .when(r.validAfter)), ("Until", .when(r.validBefore))]) }
                if !x.roles.isEmpty { NTCard(title: "Roles (\(x.roles.count))") { NTTags(values: x.roles, max: 16, kind: "role") } }
                if !x.traits.isEmpty { NTCard(title: "Traits") { NTRows(rows: ntTraitRows(x.traits.map { ($0.name, $0.values) })) } }
                NTCard(title: "Allowed") {
                    if x.permissions.isEmpty {
                        Text("Nothing — no permit-* extensions").font(.system(size: 12)).foregroundStyle(Theme.shared.p.muted)
                    } else { NTTags(values: x.permissions, kind: "perm") }
                    if !x.restrictions.isEmpty { NTRows(rows: x.restrictions.map { ($0.name, .text($0.value)) }) }
                }
                let tp = x.teleport.filter { $0.name != "Cluster" }
                if !tp.isEmpty { NTCard(title: "Teleport") { NTRows(rows: tp.map { ($0.name, .text($0.value)) }) } }
                if !x.device.isEmpty { NTCard(title: "Trusted device") { NTRows(rows: x.device.map { ($0.name, .text($0.value)) }) } }
                if !x.other.isEmpty {
                    NTCard(title: "Other extensions") { NTRows(rows: x.other.map { ($0.name, .text($0.value.isEmpty ? "(set)" : $0.value)) }) }
                }
                NTCard(title: "Key and signer") {
                    NTRows(rows: [("Key ID", .text(r.keyId)), ("Key", .text("\(r.keyType)  \(r.keyFingerprint)")),
                                  ("Signed by CA", .text("\(r.ca.type)  \(r.ca.fingerprint)")),
                                  ("Serial", .text(r.serial)), ("Comment", .text(r.comment))])
                }
            }
        }
    }
}

struct JWTView: View {
    let r: JWTResult
    var file: String? = nil
    var body: some View {
        let c = r.claims
        let sub = c.fields.first { $0.key == "sub" || $0.key == "username" }
        let iss = c.fields.first { $0.key == "iss" }
        let text = [r.kind.isEmpty ? "JWT" : r.kind,
                    sub.map { "for \($0.value ?? $0.list?.joined(separator: ", ") ?? "")" } ?? "",
                    iss.map { "from \($0.value ?? "")" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let cmd = NetPreview.jwtCommand(r)
        NTRawToggle(raw: JWTView.raw(r)) {
            VStack(alignment: .leading, spacing: 0) {
                NTHeadline(text: text, badges: [NTWhen.stateTag(r.state, r.expiresIn), (r.signature.alg ?? "no algorithm", ""),
                                                ("signature not checked", "warn")])
                NTFileCard(file: file)
                NTCmdBlock(command: cmd.command, note: cmd.note)
                NTCard(title: "Claims") {
                    NTRows(rows: c.fields.map { f in
                        (f.name == f.key ? f.key : f.name,
                         f.time != nil ? NTVal.when(f.time) : f.list != nil ? NTVal.tags(f.list!, max: 10) : .text(f.value))
                    })
                }
                if !c.roles.isEmpty { NTCard(title: "Roles (\(c.roles.count))") { NTTags(values: c.roles, max: 16, kind: "role") } }
                if !c.traits.isEmpty { NTCard(title: "Traits") { NTRows(rows: ntTraitRows(c.traits.map { ($0.name, $0.values) })) } }
                NTCard(title: "Header") {
                    NTRows(rows: r.header.entries.sorted { $0.key < $1.key }.map { k, v in
                        (k, .text({ if case .object = v { return v.jsText() }; if case .array = v { return v.jsText() }; return ntJSString(v) }()))
                    })
                }
            }
        }
    }
    static func raw(_ r: JWTResult) -> String {
        ["// header", r.header.jsText(indent: 2), "", "// claims", r.payload.jsText(indent: 2), "",
         "// encoded parts (header . payload . signature)", r.raw.header, r.raw.payload, r.raw.signature].joined(separator: "\n")
    }
}

struct SVIDView: View {
    let r: SVIDResult
    var file: String? = nil
    var body: some View {
        let leaf = r.certificates[0]
        NTRawToggle(raw: SVIDView.raw(r)) {
            VStack(alignment: .leading, spacing: 0) {
                NTHeadline(text: leaf.spiffeId ?? "No SPIFFE ID in this certificate",
                           badges: [NTWhen.stateTag(leaf.state, leaf.expiresIn),
                                    (r.ok ? "keeps the SPIFFE rules" : "breaks the SPIFFE rules", r.ok ? "ok" : "bad")])
                NTFileCard(file: file)
                // A heredoc, not a one-line pipe: a certificate has real
                // newlines, and disturbing those gives "unable to load certificate".
                NTCmdBlock(command: NetPreview.svidCommand(r))
                if !leaf.problems.isEmpty {
                    NTCard(title: "Problems") {
                        ForEach(leaf.problems, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Theme.shared.p.red) }
                    }
                }
                ForEach(Array(r.certificates.enumerated()), id: \.offset) { i, c in
                    NTCard(title: i == 0 ? "The SVID" : "Chain certificate \(i)") { NTRows(rows: SVIDView.rows(c, first: i == 0)) }
                }
            }
        }
    }
    static func rows(_ c: SVIDResult.Cert, first: Bool) -> [(String, NTVal)] {
        var out: [(String, NTVal)] = []
        if first, let id = c.spiffeId, let m = NetCheck.firstMatch("^spiffe://([^/]+)(/.*)?$", id) {
            out.append(("Trust domain", .text(m[1] ?? "")))
            out.append(("Workload path", .text(m[2] ?? "/")))
        }
        let others = c.sans.filter { $0 != "URI:" + (c.spiffeId ?? "") }
        out += [("Subject", .text(c.subject)), ("Issuer", .text(c.issuer)), ("Valid from", .when(c.validFrom)),
                ("Valid until", .when(c.validTo)), ("Certificate authority", .text(c.ca ? "yes" : "no")),
                ("Key", .text(c.publicKey)), ("Key usage", c.keyUsage.isEmpty ? .text(nil) : .tags(c.keyUsage)),
                ("Other names", others.isEmpty ? .text(nil) : .tags(others)),
                ("Signed by the next one", .text(c.signedByNext.map { $0 ? "yes" : "no — the chain does not line up here" })),
                ("Serial", .text(c.serial)), ("SHA-256", .text(c.fingerprint256))]
        return out
    }
    static func raw(_ r: SVIDResult) -> String {
        let fields: [JSON] = r.certificates.map { c in
            ["subject": .string(c.subject), "issuer": .string(c.issuer), "spiffeId": JSON(c.spiffeId),
             "sans": JSON(c.sans), "serial": .string(c.serial), "validFrom": .string(c.validFrom),
             "validTo": .string(c.validTo), "state": .string(c.state), "expiresIn": JSON(Double(c.expiresIn)),
             "ca": .bool(c.ca), "keyUsage": JSON(c.keyUsage), "publicKey": .string(c.publicKey),
             "fingerprint256": .string(c.fingerprint256), "signedByNext": JSON(c.signedByNext), "problems": JSON(c.problems)]
        }
        return r.pem + "\n\n" + JSON.array(fields).jsText(indent: 2)
    }
}
