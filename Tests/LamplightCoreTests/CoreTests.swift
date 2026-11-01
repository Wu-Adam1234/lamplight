import XCTest
@testable import LamplightCore

final class SessionLengthTests: XCTestCase {
    func testDefaultStorageIsUntilStopped() {
        XCTAssertEqual(SessionLength(storageValue: 0), .untilStopped)
        XCTAssertEqual(SessionLength(storageValue: -5), .untilStopped)
        XCTAssertEqual(SessionLength.untilStopped.storageValue, 0)
        XCTAssertNil(SessionLength.untilStopped.duration)
    }

    func testMinutesRoundTrip() {
        for length in SessionLength.presets {
            XCTAssertEqual(SessionLength(storageValue: length.storageValue), length)
        }
        XCTAssertEqual(SessionLength.minutes(30).duration, 1800)
    }

    func testTitles() {
        XCTAssertEqual(SessionLength.untilStopped.title, "Until I turn it off")
        XCTAssertEqual(SessionLength.minutes(15).title, "15 minutes")
        XCTAssertEqual(SessionLength.minutes(1).title, "1 minute")
        XCTAssertEqual(SessionLength.minutes(60).title, "1 hour")
        XCTAssertEqual(SessionLength.minutes(480).title, "8 hours")
        XCTAssertEqual(SessionLength.minutes(90).title, "1 h 30 min")
    }
}

final class SessionTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func testUntilStoppedNeverFinishes() {
        let s = Session(startedAt: start, length: .untilStopped)
        XCTAssertNil(s.endsAt)
        XCTAssertNil(s.remaining(at: start.addingTimeInterval(1_000_000)))
        XCTAssertFalse(s.isFinished(at: start.addingTimeInterval(1_000_000)))
    }

    func testTimedSessionCountsDownAndFinishes() {
        let s = Session(startedAt: start, length: .minutes(15))
        XCTAssertEqual(s.endsAt, start.addingTimeInterval(900))
        XCTAssertEqual(s.remaining(at: start.addingTimeInterval(300)), 600)
        XCTAssertFalse(s.isFinished(at: start.addingTimeInterval(899)))
        XCTAssertTrue(s.isFinished(at: start.addingTimeInterval(900)))
        XCTAssertEqual(s.remaining(at: start.addingTimeInterval(5000)), 0)
    }
}

final class TimeTextTests: XCTestCase {
    func testRemainingRoundsUp() {
        XCTAssertEqual(TimeText.remaining(1), "1 min left")
        XCTAssertEqual(TimeText.remaining(59 * 60 + 1), "1 h 00 min left")
        XCTAssertEqual(TimeText.remaining(42 * 60), "42 min left")
        XCTAssertEqual(TimeText.remaining(65 * 60), "1 h 05 min left")
    }

    func testCompact() {
        XCTAssertEqual(TimeText.compact(42 * 60), "42m")
        XCTAssertEqual(TimeText.compact(125 * 60), "2:05")
        XCTAssertEqual(TimeText.compact(0), "0m")
    }

    func testClockUsesLocale() {
        let date = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TimeText.clock(date, locale: Locale(identifier: "en_GB"), timeZone: utc), "00:00")
    }
}

final class LidRuleTests: XCTestCase {
    func testRuleAllowsOnlyTheTwoPmsetCommands() {
        XCTAssertEqual(
            LidRule.rule(for: "adam"),
            "adam ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        )
    }

    func testUnsafeUsernamesAreRefused() {
        for bad in ["", "-root", "%admin", "a b", "x'y", "a;rm -rf /", "a\nb", "ALL=(ALL)", "ALL", "all", "ü", "1abc", String(repeating: "a", count: 65)] {
            XCTAssertNil(LidRule.rule(for: bad), "accepted \(bad)")
            XCTAssertNil(LidRule.installCommand(for: bad), "accepted \(bad)")
        }
        for good in ["adam", "adam.wu", "j_doe-2", "_svc"] {
            XCTAssertNotNil(LidRule.rule(for: good), "refused \(good)")
        }
    }

    func testInstallCommandChecksWithVisudoAndCleansUp() throws {
        let cmd = try XCTUnwrap(LidRule.installCommand(for: "adam"))
        XCTAssertTrue(cmd.contains("/usr/sbin/visudo -cf"))
        XCTAssertTrue(cmd.contains("install -m 0440 -o root -g wheel"))
        XCTAssertTrue(cmd.hasSuffix("; S=$?; /bin/rm -f \"$T\" /etc/sudoers.d/.lamplight.new; exit $S"))
        // staged under a dotted name (ignored by sudo), then moved into place atomically
        XCTAssertTrue(cmd.contains("install -m 0440 -o root -g wheel \"$T\" /etc/sudoers.d/.lamplight.new && /bin/mv -f /etc/sudoers.d/.lamplight.new /etc/sudoers.d/lamplight"))
        // visudo must run before install
        let visudo = try XCTUnwrap(cmd.range(of: "visudo"))
        let install = try XCTUnwrap(cmd.range(of: "/usr/bin/install"))
        XCTAssertLessThan(visudo.lowerBound, install.lowerBound)
    }

    func testRuleIsAValidSudoersFile() throws {
        let rule = try XCTUnwrap(LidRule.rule(for: "adam"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rule")
        try (rule + "\n").write(to: file, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        p.arguments = ["-cf", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "visudo rejected: \(rule)")
    }

    func testParsesPmsetOutput() {
        let on = " SleepDisabled\t\t1\n displaysleep         10\n"
        let off = "System-wide power settings:\n SleepDisabled\t\t0\n"
        XCTAssertEqual(LidRule.sleepDisabled(inPmsetOutput: on), true)
        XCTAssertEqual(LidRule.sleepDisabled(inPmsetOutput: off), false)
        XCTAssertNil(LidRule.sleepDisabled(inPmsetOutput: " sleep 1\n"))
    }
}

final class BatteryGuardTests: XCTestCase {
    func testStopsOnlyOnBatteryAtOrBelowThreshold() {
        let guardian = BatteryGuard(threshold: 10)
        XCTAssertTrue(guardian.shouldStop(onBattery: true, percent: 10))
        XCTAssertTrue(guardian.shouldStop(onBattery: true, percent: 3))
        XCTAssertFalse(guardian.shouldStop(onBattery: true, percent: 11))
        XCTAssertFalse(guardian.shouldStop(onBattery: false, percent: 2))
        XCTAssertFalse(guardian.shouldStop(onBattery: true, percent: nil))
    }

    func testZeroMeansNever() {
        XCTAssertFalse(BatteryGuard(threshold: 0).shouldStop(onBattery: true, percent: 1))
    }

    func testThresholdIsClamped() {
        XCTAssertEqual(BatteryGuard(threshold: -4).threshold, 0)
        XCTAssertEqual(BatteryGuard(threshold: 400).threshold, 100)
    }
}
