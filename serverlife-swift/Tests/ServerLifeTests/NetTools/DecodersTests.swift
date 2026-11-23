import Testing
import Foundation
@testable import ServerLife

// tests/decoders.test.mjs and tests/sockets.test.mjs.

private func sh(_ exe: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
}

private func tmpDir(_ p: String) -> String {
    let d = NSTemporaryDirectory() + p + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func b64url(_ j: JSON) -> String {
    Data(j.jsText().utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

@Suite struct NetToolsDecoders {
    @Test func subnetWithHostBits() throws {
        let r = try NTDecode.cidr("10.0.0.5/24 10.0.0.200")
        #expect(r.cidr == "10.0.0.0/24")
        #expect(r.hostBitsSet)
        #expect(r.first == "10.0.0.1")
        #expect(r.last == "10.0.0.254")
        #expect(r.broadcast == "10.0.0.255")
        #expect(r.usable == "254")
        #expect(r.check == .init(address: "10.0.0.200", inside: true))
        #expect(try NTDecode.cidr("172.16.0.0/12", check: "172.32.0.1").check?.inside == false)
    }

    @Test func netmaskAndSmallPrefixes() throws {
        #expect(try NTDecode.cidr("192.168.1.0 255.255.240.0").cidr == "192.168.0.0/20")
        #expect(try NTDecode.cidr("10.0.0.0/31").usable == "2")
        #expect(try NTDecode.cidr("10.0.0.9").cidr == "10.0.0.9/32")
        #expect(NTAddr.maskToPrefix("255.0.255.0") == nil)
    }

    @Test func ipv6IsCompressed() throws {
        let r = try NTDecode.cidr("2001:db8:0:0:1::1/64")
        #expect(r.network == "2001:db8::")
        #expect(r.lastAddress == "2001:db8::ffff:ffff:ffff:ffff")
        #expect(NTAddr.v6String(NTAddr.v6Bytes("::ffff:10.0.0.1")) == "::ffff:a00:1")
        #expect(throws: AppError.self) { try NTDecode.cidr("10.0.0.0/33") }
        do { _ = try NTDecode.cidr("10.0.0.0/33") } catch { #expect("\(error)".contains("prefix") || ((error as? AppError)?.message.contains("prefix") ?? false)) }
    }

    @Test func url() throws {
        let r = try NTDecode.url("https://ex.com/a%20b?x=1&y=hello%20world")
        #expect(r.decoded == "https://ex.com/a b?x=1&y=hello world")
        #expect(r.query == [.init(key: "x", value: "1"), .init(key: "y", value: "hello world")])
        #expect(r.parts?.host == "ex.com")
        #expect(try NTDecode.url("a b&c").encoded == "a%20b%26c")
        #expect(try NTDecode.url("plain").decoded == nil)
    }

    @Test func jwt() throws {
        let tok = [b64url(["alg": "RS256"]), b64url(["sub": "spiffe://ex.org/w", "exp": 2000, "iat": 1000]), "c2ln"].joined(separator: ".")
        let r = try NTDecode.jwt("Bearer " + tok, now: 1500 * 1000)
        #expect(r.state == "valid")
        #expect(r.kind == "JWT-SVID (SPIFFE)")
        #expect(r.expiresIn == 500)
        #expect(r.signature.verified == false)
        #expect(try NTDecode.jwt(tok, now: 3000 * 1000).state == "expired")
        do { _ = try NTDecode.jwt("a.b"); Issue.record("no throw") } catch {
            #expect((error as? AppError)?.message.contains("three parts") == true)
        }
    }

    @Test func jwtClaimsInReadingOrder() throws {
        let payload: JSON = ["exp": 2000, "roles": ["access"], "traits": ["logins": ["bob"]], "iss": "teleport",
                             "sub": "bob", "aud": ["https://app"], "iat": 1000]
        let tok = [b64url(["alg": "RS256"]), b64url(payload), "c2ln"].joined(separator: ".")
        let r = try NTDecode.jwt(tok, now: 1500 * 1000)
        #expect(r.claims.fields.map(\.key) == ["iss", "sub", "aud", "iat", "exp"])
        #expect(r.claims.fields.first { $0.key == "exp" }?.time == "1970-01-01T00:33:20.000Z")
        #expect(r.claims.fields.first { $0.key == "aud" }?.list == ["https://app"])
        #expect(r.claims.roles == ["access"])
        #expect(r.claims.traits == [.init(name: "logins", values: ["bob"])])
        #expect(r.raw.signature == "c2ln")
        #expect(r.kind == "Teleport application token" || r.kind == "")
    }

    @Test func sshCertificate() throws {
        let dir = tmpDir("slcert-")
        let kg = "/usr/bin/ssh-keygen"
        _ = sh(kg, ["-q", "-t", "ed25519", "-N", "", "-f", dir + "/ca"])
        _ = sh(kg, ["-q", "-t", "ecdsa", "-N", "", "-f", dir + "/user"])
        _ = sh(kg, ["-q", "-s", dir + "/ca", "-I", "alice", "-n", "alice,root", "-V", "+1h",
                    "-O", "extension:teleport-roles=dev", dir + "/user.pub"])
        let r = try NTDecode.sshCert(try String(contentsOfFile: dir + "/user-cert.pub", encoding: .utf8))
        let listed = sh(kg, ["-L", "-f", dir + "/user-cert.pub"]) ?? ""
        #expect(r.type == "user")
        #expect(r.principals == ["alice", "root"])
        #expect(r.state == "valid")
        #expect(r.teleport)
        #expect(listed.contains(r.keyFingerprint))
        #expect(listed.contains(r.ca.fingerprint))
        do { _ = try NTDecode.sshCert(try String(contentsOfFile: dir + "/user.pub", encoding: .utf8)); Issue.record("no throw") }
        catch { #expect((error as? AppError)?.message.contains("plain key") == true) }
    }

    @Test func sshCertificateExtensionsSorted() throws {
        let dir = tmpDir("slcert2-")
        let kg = "/usr/bin/ssh-keygen"
        _ = sh(kg, ["-q", "-t", "ed25519", "-N", "", "-f", dir + "/ca"])
        _ = sh(kg, ["-q", "-t", "ed25519", "-N", "", "-f", dir + "/user"])
        _ = sh(kg, ["-q", "-s", dir + "/ca", "-I", "bob@example.com", "-n", "bob,-teleport-internal-join", "-V", "+1h",
                    "-O", "clear", "-O", "permit-pty", "-O", "source-address=10.0.0.0/8",
                    "-O", "extension:teleport-roles={\"roles\":[\"access\",\"editor\"]}",
                    "-O", "extension:teleport-traits={\"logins\":[\"bob\"],\"groups\":[\"a\",\"b\",\"\"]}",
                    "-O", "extension:teleport-route-to-cluster=example.com",
                    "-O", "extension:teleport-device-asset-tag=TAG1",
                    "-O", "extension:something@else.org=x", dir + "/user.pub"])
        let file = dir + "/user-cert.pub"
        let r = try NTDecode.sshCert(try String(contentsOfFile: file, encoding: .utf8))
        let x = r.readable
        #expect(x.permissions == ["Interactive terminal"])
        #expect(x.roles == ["access", "editor"])
        #expect(x.traits == [.init(name: "groups", values: ["a", "b"]), .init(name: "logins", values: ["bob"])])
        #expect(x.teleport == [.init(name: "Cluster", value: "example.com")])
        #expect(x.device == [.init(name: "Asset tag", value: "TAG1")])
        #expect(x.other == [.init(name: "something@else.org", value: "x")])
        #expect(x.restrictions == [.init(name: "Only from", value: "10.0.0.0/8")])
        let listed = (sh(kg, ["-L", "-f", file]) ?? "").components(separatedBy: "\n")[1..<7]
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        #expect(Array(r.raw.components(separatedBy: "\n").prefix(6)) == listed)
    }

    @Test func svid() throws {
        let dir = tmpDir("slsvid-")
        let openssl = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/openssl") ? "/opt/homebrew/bin/openssl" : "/usr/bin/openssl"
        func make(_ san: String, _ ca: String, rsa: Bool = false) throws -> String {
            let out = dir + "/c\(UUID().uuidString).pem"
            let key = rsa ? ["-newkey", "rsa:2048"] : ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"]
            _ = sh(openssl, ["req", "-x509"] + key + ["-nodes",
                                        "-keyout", dir + "/k.pem", "-out", out, "-days", "1", "-subj", "/O=SPIFFE",
                                        "-addext", "subjectAltName=\(san)", "-addext", "basicConstraints=critical,CA:\(ca)"])
            return try String(contentsOfFile: out, encoding: .utf8)
        }
        let good = try NTDecode.svid(try make("URI:spiffe://example.org/ns/prod/sa/web", "FALSE"))
        #expect(good.ok)
        #expect(good.spiffeId == "spiffe://example.org/ns/prod/sa/web")
        #expect(good.certificates[0].subject == "O=SPIFFE")
        // LibreSSL writes the curve out in full rather than naming it.
        #expect(good.certificates[0].publicKey.hasPrefix("ec"))
        let bad = try NTDecode.svid(try make("URI:spiffe://Example.org", "TRUE"))
        #expect(!bad.ok)
        #expect(bad.certificates[0].problems.count == 3)
        // A self-signed CA, pasted before itself, chains to itself.
        let caPem = try make("URI:spiffe://example.org/ca", "TRUE", rsa: true)
        let chain = try NTDecode.svid(caPem + "\n" + caPem)
        #expect(chain.certificates[0].signedByNext == true)
        #expect(chain.certificates[0].publicKey == "rsa 2048")
        #expect(chain.certificates[1].signedByNext == nil)
    }
}

@Suite struct NetToolsSockets {
    @Test func splitAddrPort() {
        let s = NetSockets.splitAddrPort
        #expect(s("10.0.0.5:443") == ("10.0.0.5", 443))
        #expect(s("[::1]:443") == ("::1", 443))
        #expect(s(":::22") == ("::", 22))
        #expect(s("0.0.0.0:*") == ("0.0.0.0", nil))
        #expect(s("*:*") == (nil, nil))
        #expect(s("") == (nil, nil))
    }

    @Test func ss() {
        let text = [
            "Netid  State   Recv-Q  Send-Q    Local Address:Port     Peer Address:Port   Process",
            "tcp    LISTEN  0       128             0.0.0.0:22            0.0.0.0:*      users:((\"sshd\",pid=123,fd=3))",
            "tcp    ESTAB   0       0              10.0.0.5:22           10.0.0.8:51515  users:((\"sshd\",pid=456,fd=4))",
            "udp    UNCONN  0       0               0.0.0.0:68             0.0.0.0:*     users:((\"dhclient\",pid=789,fd=20))",
        ].joined(separator: "\n")
        let rows = NetSockets.parseSs(text)
        #expect(rows.count == 3)
        #expect(rows[0] == SocketRow(proto: "tcp", state: "LISTEN", localAddr: "0.0.0.0", localPort: 22, remoteAddr: nil,
                                     remotePort: nil, pid: 123, process: "sshd", line: rows[0].line))
        #expect(rows[1].remoteAddr == "10.0.0.8" && rows[1].remotePort == 51515 && rows[1].pid == 456)
        #expect(rows[2].proto == "udp" && rows[2].state == "" && rows[2].process == "dhclient")
    }

    @Test func netstat() {
        let text = [
            "Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name",
            "tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      123/sshd",
            "udp        0      0 0.0.0.0:68              0.0.0.0:*                           456/dhclient",
        ].joined(separator: "\n")
        let rows = NetSockets.parseNetstatLinux(text)
        #expect(rows.count == 2)
        #expect(rows[0].state == "LISTEN" && rows[0].pid == 123 && rows[0].process == "sshd")
        #expect(rows[1].proto == "udp" && rows[1].state == "" && rows[1].pid == 456 && rows[1].process == "dhclient")
    }

    @Test func lsof() {
        let text = [
            "COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME",
            "sshd      123   root   3u   IPv4 0x1234      0t0  TCP  *:22 (LISTEN)",
            "sshd      456   root   10u  IPv4 0x5678      0t0  TCP  10.0.0.5:22->10.0.0.8:51515 (ESTABLISHED)",
            "mdnsd     77    _mdns  4u   IPv4 0x9999      0t0  UDP  *:5353",
        ].joined(separator: "\n")
        let rows = NetSockets.parseLsof(text)
        #expect(rows.count == 3)
        #expect(rows[0].proto == "tcp" && rows[0].localPort == 22 && rows[0].state == "LISTEN" && rows[0].pid == 123 && rows[0].process == "sshd")
        #expect(rows[1].remoteAddr == "10.0.0.8" && rows[1].remotePort == 51515 && rows[1].state == "ESTABLISHED")
        #expect(rows[2].proto == "udp" && rows[2].state == "")
    }
}
