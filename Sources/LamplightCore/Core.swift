import Foundation

// MARK: - Session length

/// How long a keep-awake session lasts. The default is `.untilStopped`.
public enum SessionLength: Hashable, Sendable {
    case untilStopped
    case minutes(Int)

    /// The lengths offered in the "Turn On For" menu.
    public static let presets: [SessionLength] = [
        .minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480)
    ]

    /// Stored in UserDefaults as an Int: 0 means until stopped, anything else is minutes.
    public init(storageValue: Int) {
        self = storageValue > 0 ? .minutes(storageValue) : .untilStopped
    }

    public var storageValue: Int {
        switch self {
        case .untilStopped: return 0
        case .minutes(let m): return max(m, 0)
        }
    }

    public var duration: TimeInterval? {
        switch self {
        case .untilStopped: return nil
        case .minutes(let m): return TimeInterval(m * 60)
        }
    }

    public var title: String {
        switch self {
        case .untilStopped:
            return "Until I turn it off"
        case .minutes(let m) where m < 60:
            return m == 1 ? "1 minute" : "\(m) minutes"
        case .minutes(let m) where m % 60 == 0:
            let h = m / 60
            return h == 1 ? "1 hour" : "\(h) hours"
        case .minutes(let m):
            return "\(m / 60) h \(m % 60) min"
        }
    }
}

// MARK: - Session

/// A running keep-awake session.
public struct Session: Equatable, Sendable {
    public let startedAt: Date
    public let length: SessionLength

    public init(startedAt: Date, length: SessionLength) {
        self.startedAt = startedAt
        self.length = length
    }

    public var endsAt: Date? {
        length.duration.map { startedAt.addingTimeInterval($0) }
    }

    /// Seconds left, or nil when the session runs until stopped.
    public func remaining(at now: Date) -> TimeInterval? {
        endsAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func isFinished(at now: Date) -> Bool {
        guard let left = remaining(at: now) else { return false }
        return left <= 0
    }
}

// MARK: - Formatting

public enum TimeText {
    /// Rounds up, so "0 min left" never shows while the session is still running.
    static func wholeMinutes(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) / 60).rounded(.up))
    }

    /// For the menu: "42 min left", "1 h 05 min left".
    public static func remaining(_ seconds: TimeInterval) -> String {
        let total = wholeMinutes(seconds)
        if total < 60 { return "\(total) min left" }
        return String(format: "%d h %02d min left", total / 60, total % 60)
    }

    /// For the menu bar, kept short: "42m", "1:05".
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = wholeMinutes(seconds)
        if total < 60 { return "\(total)m" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "6:30 PM", in the user's locale.
    public static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Lid-closed permission (sudoers rule)

/// Closing the lid sleeps a Mac no matter which power assertions are held.
/// The only switch that stops that is `pmset -a disablesleep 1`, which needs root.
/// Lamplight installs one sudoers rule that allows exactly two commands, and nothing else:
///     /usr/bin/pmset -a disablesleep 1
///     /usr/bin/pmset -a disablesleep 0
public enum LidRule {
    public static let filePath = "/etc/sudoers.d/lamplight"
    public static let pmset = "/usr/bin/pmset"
    public static let onArguments = ["-a", "disablesleep", "1"]
    public static let offArguments = ["-a", "disablesleep", "0"]

    /// Only plain account names. Anything else is refused, so nothing odd can reach sudoers or the shell.
    public static func isSafeUsername(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64 else { return false }
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789.-"))
        guard letters.contains(first), name.uppercased() != "ALL" else { return false }
        return name.unicodeScalars.allSatisfy { rest.contains($0) }
    }

    /// The single line written to /etc/sudoers.d/lamplight.
    public static func rule(for user: String) -> String? {
        guard isSafeUsername(user) else { return nil }
        let on = ([pmset] + onArguments).joined(separator: " ")
        let off = ([pmset] + offArguments).joined(separator: " ")
        return "\(user) ALL=(root) NOPASSWD: \(on), \(off)"
    }

    /// Where the rule is staged first. sudo ignores files in sudoers.d whose names contain a dot,
    /// so a half-written staging file can never break sudo; the final `mv` is atomic.
    public static let stagingPath = "/etc/sudoers.d/.lamplight.new"

    /// Shell command run once, as root, behind the macOS admin password prompt.
    /// visudo checks the rule before it is installed, and the temp files are always removed.
    public static func installCommand(for user: String) -> String? {
        guard let line = rule(for: user) else { return nil }
        return [
            "T=$(/usr/bin/mktemp /tmp/lamplight.XXXXXX)",
            "/usr/bin/printf '%s\\n' '\(line)' > \"$T\"",
            "/usr/sbin/visudo -cf \"$T\" > /dev/null",
            "/bin/mkdir -p /etc/sudoers.d",
            "/usr/bin/install -m 0440 -o root -g wheel \"$T\" \(stagingPath)",
            "/bin/mv -f \(stagingPath) \(filePath)"
        ].joined(separator: " && ") + "; S=$?; /bin/rm -f \"$T\" \(stagingPath); exit $S"
    }

    /// Removes the rule and makes sure normal sleep is back on.
    public static var uninstallCommand: String {
        "/bin/rm -f \(filePath); \(pmset) \(offArguments.joined(separator: " "))"
    }

    /// Reads `SleepDisabled` out of `pmset -g` output.
    public static func sleepDisabled(inPmsetOutput output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return nil
    }
}

// MARK: - Battery guard

/// With the lid shut and sleep switched off, a laptop on battery runs until it is flat.
/// This policy ends the session first.
public struct BatteryGuard: Equatable, Sendable {
    public static let choices = [0, 5, 10, 20, 30]
    public static let defaultThreshold = 10

    /// 0 means never stop for battery.
    public var threshold: Int

    public init(threshold: Int) {
        self.threshold = max(0, min(threshold, 100))
    }

    public func shouldStop(onBattery: Bool, percent: Int?) -> Bool {
        guard threshold > 0, onBattery, let percent else { return false }
        return percent <= threshold
    }
}
