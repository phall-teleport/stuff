import Testing
import Foundation
@testable import ServerLife

// The 0.39 additions to tests/nettools.test.mjs and tests/sshkeys.test.mjs.

@Suite("NetToolsCommands") struct NetToolsCommandsTests {
    private func preview(_ f: (inout NetPreviewInput) -> Void) -> String {
        var i = NetPreviewInput()
        f(&i)
        return NetPreview.command(i).command ?? ""
    }

    @Test func pingAndTracerouteCanBeForcedOntoOneFamily() {
        let ping6 = preview { $0.tool = "ping"; $0.host = "example.com"; $0.ipVersion = "6" }
        let trace6 = preview { $0.tool = "traceroute"; $0.host = "example.com"; $0.ipVersion = "6" }
        #expect(ping6.hasPrefix("ping6 "))
        #expect(trace6.hasPrefix("traceroute6 "))
        let ping4 = preview { $0.tool = "ping"; $0.host = "example.com"; $0.ipVersion = "4" }
        #expect(!ping4.hasPrefix("ping6"))
        #expect(ping4.range(of: #"-6\b"#, options: .regularExpression) == nil)
    }

    @Test func portCheckCanBeForcedOntoOneFamily() {
        let c = preview { $0.tool = "ports"; $0.host = "example.com"; $0.ports = "443"; $0.ipVersion = "6" }
        #expect(c.hasPrefix("nc -zv -6 "))
    }

    @Test func dnsCanUseANameserver() {
        let c = preview { $0.tool = "dns"; $0.host = "example.com"; $0.server = "1.1.1.1" }
        #expect(c.contains("nslookup -type=A example.com 1.1.1.1"))
        let none = preview { $0.tool = "dns"; $0.host = "example.com" }
        #expect(!none.contains("1.1.1.1"))
        let types = NetLocal.dnsTypes.map(\.0)
        for t in ["CAA", "SOA", "NAPTR"] { #expect(types.contains(t)) }
    }

    @Test func startTLSPortsAndFlag() {
        #expect(NetTLS.startTLSPorts == ["smtp": 587, "imap": 143, "pop3": 110])
        let c = preview { $0.tool = "tls"; $0.host = "mail.example.com"; $0.starttls = "smtp" }
        #expect(c.contains("-starttls smtp"))
        #expect(c.contains("mail.example.com:587"))
    }

    @Test func telnetCommandIsNc() {
        #expect(NetLocal.telnetCommand("127.0.0.1", 23) == "nc -v 127.0.0.1 23")
    }

    @Test func httpCommandCarriesHeaders() {
        let c = NetTLS.httpCommand("http://127.0.0.1:8080/", "GET", false, "X-Request-Id: abc123")
        #expect(c.contains("-H 'X-Request-Id: abc123'"))
    }

    @Test func curlExtrasAreOptInFlags() throws {
        var o = CurlOptions()
        o.url = "https://internal.example.com"
        o.resolve = "internal.example.com:443:10.0.0.5"
        o.caCert = "/etc/ssl/internal-ca.pem"
        o.clientCert = "/home/me/client.pem"
        o.clientKey = "/home/me/client.key"
        let args = try NetCurl.args(o).args
        func after(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(after("--resolve") == "internal.example.com:443:10.0.0.5")
        #expect(after("--cacert") == "/etc/ssl/internal-ca.pem")
        #expect(after("--cert") == "/home/me/client.pem")
        #expect(after("--key") == "/home/me/client.key")
        var plain = CurlOptions()
        plain.url = "https://example.com"
        #expect(!(try NetCurl.args(plain).args).contains("--resolve"))
    }

    @Test func malformedResolveIsRejected() {
        var o = CurlOptions()
        o.url = "https://example.com"
        o.resolve = "not-the-right-shape"
        #expect(throws: (any Error).self) { try NetCurl.args(o) }
        do { _ = try NetCurl.args(o) } catch { #expect(error.localizedDescription.contains("--resolve")) }
    }

    @Test func sameCertMatchesOnTheKeyField() {
        let file = "ssh-ed25519-cert-v01@openssh.com AAAAC3NzaC1lZDI1NTE5 me@host\n"
        #expect(NetDecodeIO.sameCert("ssh-ed25519-cert-v01@openssh.com\n AAAAC3Nza C1lZDI1NTE5", file))
        #expect(!NetDecodeIO.sameCert("something else", file))
    }
}

@Suite("NetToolsSSHKeys") struct NetToolsSSHKeysTests {
    private func header(_ cipher: String, _ trailing: String = "") -> String {
        var raw = Array("openssh-key-v1\0".utf8)
        let c = Array(cipher.utf8)
        raw += [UInt8(c.count >> 24 & 0xff), UInt8(c.count >> 16 & 0xff), UInt8(c.count >> 8 & 0xff), UInt8(c.count & 0xff)]
        raw += c + Array(trailing.utf8)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(Data(raw).base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    @Test func noneCipherIsPlain() { #expect(SSHKeys.opensshKeyEncrypted(header("none")) == false) }
    @Test func otherCipherIsEncrypted() { #expect(SSHKeys.opensshKeyEncrypted(header("aes256-ctr")) == true) }
    @Test func noneInACommentIsNotTheCipher() {
        #expect(SSHKeys.opensshKeyEncrypted(header("aes256-ctr", "steven@none-prod-bastion")) == true)
    }
    @Test func badHeaderIsInconclusive() {
        #expect(SSHKeys.opensshKeyEncrypted("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n") == nil)
        #expect(SSHKeys.opensshKeyEncrypted("-----BEGIN OPENSSH PRIVATE KEY-----\n\n-----END OPENSSH PRIVATE KEY-----\n") == nil)
    }
}
