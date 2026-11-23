import Testing
import Foundation
@testable import ServerLife

/// tests/search.test.mjs.
@Suite struct MiscSearchTests {
    typealias S = MiscSearch

    @Test func everyWordHasToBeFoundAndANameThatStartsWithItRanksFirst() {
        #expect(S.scoreMatch("prod web", "web-01", "env=staging") == 0)
        #expect(S.scoreMatch("prod web", "web-01", "env=prod") > 0)
        #expect(S.scoreMatch("web", "web-01") > S.scoreMatch("web", "old-web-01"))
        #expect(S.scoreMatch("web", "old-web-01") > S.scoreMatch("web", "cobweb"))
        #expect(S.scoreMatch("web", "cobweb") > S.scoreMatch("web", "db-01", "role=web"))
        #expect(S.scoreMatch("", "anything") == 0)
        // Characters that mean something in a pattern are only characters.
        #expect(S.scoreMatch("a.b(", "x a.b( y") > 0)
    }

    @Test func resultsComeGroupedByKindBestKindFirstAFewOfEach() {
        var items = [S.Item(kind: "command", name: "Multi-exec", extra: "run command")]
        for i in 0..<9 { items.append(S.Item(kind: "host", name: "db-\(i)", extra: "multi")) }
        let g = S.rank(items, "multi")
        #expect(g[0].kind == "command")
        #expect(g[1].kind == "host")
        #expect(g[1].items.count == 6)
        #expect(g[1].more == 3)
    }

    @Test func everyCommandHasAKindTitleAndNoRepeats() {
        let names = S.commands.map(\.0)
        #expect(Set(names).count == names.count)
        #expect(S.kindTitle("setting") == "Settings")
        #expect(S.kinds.count == 13)
    }
}

/// tests/fonts.test.mjs.
@Suite struct MiscFontsTests {
    typealias F = MiscFonts

    @Test func nothingChosenIsTheDefaultStack() {
        #expect(F.stack("") == F.defaultStack)
        #expect(F.stack(nil) == F.defaultStack)
    }

    @Test func oneFamilyIsQuotedAndGivenTheFallbacks() {
        #expect(F.stack("JetBrains Mono") == "\"JetBrains Mono\", \(F.defaultStack)")
        #expect(F.stack("\"Fira Code\"") == "\"Fira Code\", \(F.defaultStack)")
    }

    @Test func aStackSomeoneTypedIsUsedAsItIs() {
        #expect(F.stack("\"My Font\", Menlo, monospace") == "\"My Font\", Menlo, monospace")
    }

    @Test func theDefaultEndsInAGenericFamilyAndTheListsHaveNoRepeats() {
        #expect(F.defaultStack.hasSuffix("monospace"))
        #expect(Set(F.monoFonts).count == F.monoFonts.count)
        #expect(F.bundled.count == 51)
        #expect(F.bundledSet.count == F.bundled.count)
    }
}

/// teleport.js `parseEnvText` and the homes notes, as Settings shows them.
@Suite struct MiscTshEnvTests {
    typealias E = MiscTshEnv

    @Test func linesAreNameValueAndExportIsReadAsPasted() {
        let r = E.parse("# a comment\nTELEPORT_TOOLS_VERSION=18.11.9\n\nexport FOO=\"bar baz\"\nnot a line\n")
        #expect(r.vars.map(\.name) == ["TELEPORT_TOOLS_VERSION", "FOO"])
        #expect(r.dict["FOO"] == "bar baz")
        #expect(r.errors.count == 1)
        #expect(E.countVars("A=1\nB=2") == 2)
        #expect(E.names("A=1\n# C=0\nexport B=2") == ["A", "B"])
    }

    @Test func aProxyIsComparedBare() {
        #expect(E.bareProxy("https://Corp.Example.com:443/web") == "corp.example.com")
        #expect(E.bareProxy("corp.example.com:3080") == "corp.example.com:3080")
    }

    @Test func insertingTheExampleReplacesAnExistingVersionLine() {
        #expect(E.insertExample(into: "") == E.example)
        #expect(E.insertExample(into: "A=1\nexport TELEPORT_TOOLS_VERSION=17.0.0") == "A=1\n\(E.example)")
    }

    @Test func aHomeExpandsVariablesAndSaysWhichAreMissing() {
        let r = E.expandHome("$SL_TEST_HOME/x/${SL_NOPE}", env: ["SL_TEST_HOME": "/tmp/h"])
        #expect(r.path == "/tmp/h/x")
        #expect(r.unset == ["SL_NOPE"])
        #expect(E.expandHome("~", env: [:]).path == NSHomeDirectory())
    }
}

/// settingsnav.js.
@Suite struct MiscSettingsNavTests {
    typealias N = SettingsNav

    @Test func aSectionIsNamedFromItsFirstSetting() {
        #expect(N.title(forFirstLabel: "Teleport homes") == "Teleport homes and tsh")
        #expect(N.title(forFirstLabel: "Theme") == "Appearance")
        #expect(N.title(forFirstLabel: "Something new") == "Something new")
        #expect(N.title(forFirstLabel: "") == "More")
    }

    @Test func twoGroupsWithOneNameReadAsOneSection() {
        let g1 = [N.Item(label: "Theme", text: "theme")]
        let g2 = [N.Item(label: "Skin", text: "skin")]
        let g3 = [N.Item(label: "Cursor style", text: "cursor block")]
        let (sections, items) = N.organize([g1, g2, g3])
        #expect(sections.map(\.title) == ["Appearance", "Sessions and the interface"])
        #expect(sections[0].items == [0, 1])
        #expect(items.count == 3)
    }

    @Test func aSearchKeepsOnlyTheSettingsThatMatch() {
        let g1 = [N.Item(label: "Theme", text: "theme dark light")]
        let g2 = [N.Item(label: "Cursor style", text: "cursor style block bar")]
        let (sections, items) = N.organize([g1, g2])
        let v = N.visible(sections, items, query: "cursor", only: nil)
        #expect(v.items == [1])
        #expect(v.sections == [1])
        let all = N.visible(sections, items, query: "", only: 0)
        #expect(all.items == [0])
    }
}

/// index.js `remindCustomTeleport`.
@MainActor @Suite struct MiscTeleportReminderTests {
    typealias R = MiscTeleportReminder

    @Test func theUsualSetUpSaysNothing() {
        #expect(R.message(settings: [:], chosen: nil, version: nil) == nil)
    }

    @Test func aChosenTshThatRunsSaysItsVersion() {
        let m = R.message(settings: [:], chosen: ("/opt/tsh", "settings"), version: "18.1.0")
        #expect(m?.kind == .info)
        #expect(m?.text.hasPrefix("Using a custom tsh (Settings): /opt/tsh — v18.1.0.") == true)
        #expect(m?.text.hasSuffix("Settings → Teleport homes → Locate tsh / ssh… to change.") == true)
    }

    @Test func aChosenTshThatDoesNotRunIsAnError() {
        let m = R.message(settings: [:], chosen: ("/opt/tsh", "TSH_PATH"), version: nil)
        #expect(m?.kind == .error)
        #expect(m?.text.contains("The custom tsh (TSH_PATH) at /opt/tsh did not run") == true)
    }

    @Test func homesAndVariablesAreListed() {
        let s: JSON = ["tshHomes": ["~/a"], "tshEnvText": "A=1\nB=2", "clusterTshEnv": ["x.example.com": "C=3"]]
        let t = R.message(settings: s, chosen: nil, version: nil)?.text ?? ""
        #expect(t.contains("Reading Teleport homes: ~/a."))
        #expect(t.contains("A, B"))
        #expect(t.contains("…and its own for x.example.com (C)."))
    }

    @Test func settingsWinOverTheEnvironment() {
        #expect(R.chosen(["tshPath": "/a"], env: ["TSH_PATH": "/b"])?.from == "settings")
        #expect(R.chosen([:], env: ["TSH_PATH": "/b"])?.path == "/b")
        #expect(R.chosen([:], env: [:]) == nil)
    }
}

@Suite struct MiscNewThemesTests {
    @Test func matrixAndThugLifeAreThere() {
        #expect(MiscThemes.appThemes.contains { $0.id == "matrix" })
        #expect(MiscThemes.skin("thuglife") != nil)
    }
}
