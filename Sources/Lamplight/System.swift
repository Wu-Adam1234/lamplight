import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import LamplightCore
import ServiceManagement

// MARK: - Power assertions (idle sleep and screen sleep)

/// Holds the macOS power assertions that stop idle sleep while a session runs.
final class AwakeAssertions {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private(set) var isHolding = false

    func hold(keepScreenOn: Bool) {
        release()
        let reason = "Lamplight is keeping this Mac awake" as CFString
        let on = IOPMAssertionLevel(kIOPMAssertionLevelOn)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, on, reason, &systemID)
        if keepScreenOn {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, on, reason, &displayID)
        }
        isHolding = true
    }

    func release() {
        if systemID != 0 { IOPMAssertionRelease(systemID); systemID = 0 }
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
        isHolding = false
    }
}

// MARK: - Lid closed (pmset disablesleep through one sudoers rule)

enum AdminResult {
    case done
    case cancelled
    case failed(String)
}

struct LidControl {
    /// True once the one-time permission has been given.
    var isSetUp: Bool {
        FileManager.default.fileExists(atPath: LidRule.filePath)
    }

    /// Switches sleep off (true) or back on (false). Never asks for a password.
    @discardableResult
    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let args = ["-n", LidRule.pmset] + (disabled ? LidRule.onArguments : LidRule.offArguments)
        return Shell.run("/usr/bin/sudo", args).status == 0
    }

    /// A tiny separate process that waits for Lamplight to exit and then switches lid sleep back on.
    /// It covers what the app can't do itself: a crash or a force-quit (SIGKILL) while sleep is off.
    /// On a normal turn-off Lamplight restores sleep first and then stops the watchdog.
    static func startWatchdog() -> Process? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let restore = ([LidRule.pmset] + LidRule.offArguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 2; done; /usr/bin/sudo -n \(restore)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    func setUp() -> AdminResult {
        guard let command = LidRule.installCommand(for: NSUserName()) else {
            return .failed("Your account name has characters Lamplight won't put into a system file. Lid-closed mode is unavailable for this account.")
        }
        return Shell.runAsAdmin(command, prompt: "Lamplight needs your password once so your Mac can stay awake with the lid closed.")
    }

    func remove() -> AdminResult {
        Shell.runAsAdmin(LidRule.uninstallCommand, prompt: "Lamplight needs your password to remove its lid-closed permission.")
    }
}

// MARK: - Battery

struct BatteryReading {
    let percent: Int
    let onBattery: Bool
}

enum BatteryReader {
    /// Nil on Macs without a battery.
    static func read() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = info[kIOPSPowerSourceStateKey] as? String
            return BatteryReading(percent: current * 100 / max, onBattery: state == kIOPSBatteryPowerValue)
        }
        return nil
    }
}

// MARK: - Open at login

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Shell

enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(_ path: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Runs a command as root behind the standard macOS password prompt.
    static func runAsAdmin(_ command: String, prompt: String) -> AdminResult {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(quoted(command)) with prompt \(quoted(prompt)) with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return .failed("Lamplight couldn't prepare the request to macOS.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .done }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "macOS refused the change.")
    }
}
