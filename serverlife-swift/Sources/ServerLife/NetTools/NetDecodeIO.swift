import AppKit
import UniformTypeIdentifiers

// main.js decode:run, decode:tshCerts, decode:pickFile and net:pickFile.

enum NetDecodeIO {
    /// `decode:run`.
    static func run(_ kind: String, input: String, check: String? = nil) throws -> NetDisplay {
        switch kind {
        case "cidr": return .cidr(try NTDecode.cidr(input, check: check))
        case "url": return .url(try NTDecode.url(input), file: nil)
        case "jwt": return .jwt(try NTDecode.jwt(input), file: nil)
        case "sshcert": return .sshcert(try NTDecode.sshCert(input), file: nil)
        case "svid": return .svid(try NTDecode.svid(input), file: nil)
        default: throw AppError("Nothing decodes \"\(kind)\".")
        }
    }

    struct TshCertText { let cert: TshCert; let text: String }

    /// `decode:tshCerts`: under ~/.tsh and every Teleport home a profile uses.
    @MainActor static func tshCerts() -> [TshCertText] {
        var homes = [NSHomeDirectory() + "/.tsh"]
        for p in Inventory.shared.profiles where !p.homeDir.isEmpty && !homes.contains(p.homeDir) { homes.append(p.homeDir) }
        return NTDecode.tshCertificates(homes: homes).map {
            TshCertText(cert: $0, text: (try? String(contentsOfFile: $0.file, encoding: .utf8)) ?? "")
        }
    }

    /// `sameCert(pasted, fileText)`: matched on the key data, so a pasted copy
    /// of one of tsh's files finds it even after wrapping in a terminal.
    static func sameCert(_ pasted: String, _ fileText: String) -> Bool {
        let parts = fileText.ntTrimmed.split(whereSeparator: { $0.isWhitespace })
        guard parts.count > 1 else { return false }
        return pasted.filter { !$0.isWhitespace }.contains(parts[1])
    }

    /// `decode:pickFile`. SSH certificates start in tsh's keys folder, where
    /// they usually are. Capped and checked for text: these are all one-line
    /// or PEM files, and a stray binary picked by mistake should say so.
    @MainActor static func pickFile(_ kind: String, window: NSWindow?) async throws -> (file: String, text: String)? {
        let keys = NSHomeDirectory() + "/.tsh/keys"
        let p = NSOpenPanel()
        p.title = "Choose a file to decode"
        p.message = "Choose a file to decode"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        if kind == "sshcert", FileManager.default.fileExists(atPath: keys) { p.directoryURL = URL(fileURLWithPath: keys) }
        // macOS's panel has no "All files" choice beside a filter, and the
        // original always offers one — so nothing is filtered out.
        let res: NSApplication.ModalResponse
        if let window { res = await p.beginSheetModal(for: window) } else { res = p.runModal() }
        guard res == .OK, let url = p.url else { return nil }
        return try readSmall(url.path, binaryMessage: "That looks like a binary file — pick the PEM or text form.",
                             largeMessage: "That file is too large to be a certificate or token.")
    }

    static func readSmall(_ file: String, binaryMessage: String, largeMessage: String) throws -> (file: String, text: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        if size > 1024 * 1024 { throw AppError(largeMessage) }
        let d = try Data(contentsOf: URL(fileURLWithPath: file))
        if d.prefix(8000).contains(0) { throw AppError(binaryMessage) }
        return (file, String(decoding: d, as: UTF8.self))
    }

    /// `net:pickFile` — a file for one of curl's certificate fields.
    @MainActor static func pickPath(title: String, window: NSWindow?) async -> String? {
        let p = NSOpenPanel()
        p.title = title
        p.message = title
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        let res: NSApplication.ModalResponse
        if let window { res = await p.beginSheetModal(for: window) } else { res = p.runModal() }
        return res == .OK ? p.url?.path : nil
    }
}

extension CIDRResult {
    /// The result as decoders.js returns it (what Save writes, and Raw shows).
    var json: JSON {
        var o: [String: JSON] = [
            "family": .number(Double(family)), "input": .string(input), "cidr": .string(cidr), "prefix": .number(Double(prefix)),
            "network": .string(network), "hostBitsSet": .bool(hostBitsSet), "first": .string(first), "last": .string(last),
            "total": .string(total), "usable": .string(usable),
        ]
        if family == 4 {
            o["netmask"] = JSON(netmask); o["wildcard"] = JSON(wildcard); o["broadcast"] = JSON(broadcast); o["kind"] = JSON(kind)
        } else {
            o["lastAddress"] = JSON(lastAddress)
        }
        if let c = check { o["check"] = ["address": .string(c.address), "inside": .bool(c.inside)] }
        return .object(o)
    }
}

extension URLDecodeResult {
    var json: JSON {
        var o: [String: JSON] = ["encoded": .string(encoded), "encodedUrl": .string(encodedUrl), "decoded": JSON(decoded)]
        if let p = parts {
            o["parts"] = ["protocol": .string(p.proto), "username": JSON(p.username), "host": .string(p.host),
                          "port": JSON(p.port), "path": .string(p.path), "fragment": JSON(p.fragment)]
        }
        if let q = query { o["query"] = .array(q.map { ["key": .string($0.key), "value": .string($0.value)] }) }
        return .object(o)
    }
}

/// nettools.js decodeMenu: "Decode" as a submenu for the right-click menus
/// that offer it. `input` is what to decode — a terminal's selection — and
/// opens the decoder already run against it. With a Teleport `profile` and
/// nothing selected, the SSH certificate entry decodes that cluster's own
/// certificate, which is the one people want to read.
@MainActor
enum NetDecodeMenu {
    final class Target: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire(_ sender: Any?) { run() }
    }

    static func append(to menu: NSMenu, window: WindowModel?, input: String, profile: JSON?) {
        let text = input.ntTrimmed
        for t in NetTool.decodeTools {
            let item = NSMenuItem(title: t.label + (text.isEmpty ? "…" : " — the selection"), action: #selector(Target.fire(_:)), keyEquivalent: "")
            let target = Target {
                var given = text, file = ""
                if given.isEmpty, let profile, t.id == "sshcert" {
                    let certs = NetDecodeIO.tshCerts()
                    let host = (profile["proxy"].stringish ?? "").replacingOccurrences(of: ":\\d+$", with: "", options: .regularExpression)
                    let cluster = profile["cluster"].stringish
                    if let mine = certs.first(where: { $0.cert.cluster == cluster && $0.cert.proxy == host })
                        ?? certs.first(where: { $0.cert.proxy == host }) {
                        given = mine.text.ntTrimmed; file = mine.cert.file
                    } else {
                        StatusBus.shared.show("No tsh certificate found for \((cluster ?? "").isEmpty ? host : cluster!) — paste one")
                    }
                }
                NetToolsFeature.open(window: window, host: nil, tool: t.id, preset: nil, runOn: "", input: given, file: file)
            }
            item.target = target
            item.representedObject = target   // keeps the target alive with the item
            menu.addItem(item)
        }
    }
}
