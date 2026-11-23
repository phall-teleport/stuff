import Testing
import Foundation
@testable import ServerLife

// 0.16 → 0.39: monitor, ssh options, failure flags, ssh version, local stats.

@Test func monitorScriptClampsInterval() {
    #expect(ConnMonitorText.script(interval: 1).hasPrefix("i=2\n"))
    #expect(ConnMonitorText.script(interval: 600).hasPrefix("i=60\n"))
    #expect(ConnMonitorText.script(interval: .nan).hasPrefix("i=5\n"))
}

@Test func monitorParsesLines() {
    if case .hello(let c, let i)? = ConnMonitorText.parse("SLMON hello cpus=4 interval=5") {
        #expect(c == 4 && i == 5)
    } else { Issue.record("hello not parsed") }
    if case .unsupported(let os)? = ConnMonitorText.parse("SLMON unsupported=Darwin") {
        #expect(os == "Darwin")
    } else { Issue.record("unsupported not parsed") }
    let line = "SLMON cpu=125 memt=1000 mema=250 swapt=100 swapf=40 load=0.50 disk=42 rx=10 tx=20 up=3600"
    guard case .sample(let s)? = ConnMonitorText.parse(line) else { Issue.record("sample not parsed"); return }
    #expect(abs(s.cpu - 12.5) < 0.001)
    #expect(s.memTotal == 1000 * 1024)
    #expect(s.memUsed == 750 * 1024)
    #expect(s.swapUsed == 60 * 1024)
    #expect(s.disk == 42)
    #expect(ConnMonitorText.parse("hello world") == nil)
}

@Test func hostKeyChangedText() {
    #expect(ConnText.looksLikeHostKeyChanged("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"))
    #expect(ConnText.looksLikeHostKeyChanged("Host key verification failed."))
    #expect(!ConnText.looksLikeHostKeyChanged("Connection refused"))
}

@Test func sshOptionsArgs() {
    let o: JSON = ["localForwards": "8080:localhost:80", "dynamicForwards": ["1080"],
                   "jumpHost": "bastion", "extraOptions": ["ServerAliveInterval 10"], "reason": "fix"]
    #expect(SSHOptions.opensshArgs(o) == ["-L", "8080:localhost:80", "-D", "1080", "-J", "bastion",
                                          "-o", "ServerAliveInterval=10"])
    #expect(SSHOptions.tshArgs(o).contains("--reason=fix"))
    #expect(SSHOptions.summary(o).contains("SOCKS 1080"))
}

@Test func optionArgsOnlyForMaster() {
    var s = ConnSpec(type: "ssh", target: "ent")
    s.sshOptions = ["localForwards": ["8080:localhost:80"]]
    #expect(s.optionArgs().contains("-L"))
    #expect(s.optionArgs(session: true).isEmpty)
}

@Test func identityFileAddsIdentitiesOnly() {
    var s = ConnSpec(type: "ssh", target: "ent")
    s.identityFile = "~/.ssh/k"
    #expect(s.sshArgs(controlPath: "/c") == ["-o", "IdentitiesOnly=yes", "-o", "ControlPath=/c"])
}

@Test func sshVersionParse() {
    let v = SSHVersion.parse("OpenSSH_9.4p1, LibreSSL 3.3.6\n")
    #expect(v.major == 9 && v.minor == 4 && v.patch == 1)
    let old = SSHVersion.parse("OpenSSH_8.1, LibreSSL")
    #expect(old.patch == 0)
    #expect(!SSHVersion.supports("securityKeyIdentities", version: .some(old)))
    #expect(SSHVersion.supports("securityKeyIdentities", version: .some(v)))
    #expect(SSHVersion.supports("nonsense", version: .some(old)))
    #expect(SSHVersion.parse("garbage").major == nil)
    #expect(SSHVersion.supports("proxyJumpFlag", version: .some(SSHVersion.parse("garbage"))))
}

@Test func netstatIbnTotals() {
    let out = """
    Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
    lo0        16384 <Link#1>                         100     0       5000      100     0       5000     0
    en0        1500  <Link#6>    aa:bb:cc:dd:ee:ff    10      0       1000      20      0       2000     0
    en0        1500  192.168.1     192.168.1.5        10      -       1000      20      -       2000     -
    utun0      1380  <Link#9>                         5       0       300       6       0       400      0
    """
    let t = LocalMonitor.parseNetstatIbn(out)
    // As localmonitor.js: a row shorter than the header (no address — utun0)
    // is skipped, as are loopback and the per-address rows.
    #expect(t.rx == 1000)
    #expect(t.tx == 2000)
}

@MainActor @Test func localToolsEnvForOtherCommands() {
    #expect(LocalShells.toolsEnv(command: "/usr/bin/true", argv: []).isEmpty)
}
