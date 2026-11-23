import Testing
@testable import ServerLife

@Test func paneStatsDrawingHelpers() {
    #expect(PaneStatsText.sparkline([0, 50, 100]) == "▁▅█")
    #expect(PaneStatsText.level(81) == "warn" && PaneStatsText.level(93) == "bad" && PaneStatsText.level(10) == "")
    #expect(PaneStatsText.level(86, warn: 85, bad: 95) == "warn")
    #expect(PaneStatsText.uptime(90000) == "1d 1h")
    #expect(PaneStatsText.uptime(3700) == "1h 1m")
    #expect(PaneStatsText.uptime(120) == "2m")
}
