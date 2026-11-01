import AppKit
import LamplightCore

@main
enum LamplightMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render-demo"), flag + 1 < args.count {
            do {
                try DemoRenderer.render(to: URL(fileURLWithPath: args[flag + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}

/// UserDefaults key: true while Lamplight has switched lid sleep off. Read on launch and on signals.
let lidEngagedKey = "sleepSwitchedOffByLamplight"

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Key {
        static let defaultLength = "defaultLengthMinutes"
        static let lidClosed = "keepAwakeWithLidClosed"
        static let screenOn = "keepScreenOn"
        static let battery = "stopBelowBatteryPercent"
        static let showTime = "showTimeInMenuBar"
        static let lidEngaged = lidEngagedKey
    }

    static let repoURL = URL(string: "https://github.com/Wu-Adam1234/lamplight")!

    private let defaults = UserDefaults.standard
    private let assertions = AwakeAssertions()
    private let lid = LidControl()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var session: Session?
    private var sessionIgnoresBattery = false
    private var lastStopNote: String?
    private var tickTimer: Timer?
    private var endTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var watchdog: Process?
    private var terminating = false

    // MARK: Settings

    private var defaultLength: SessionLength {
        get { SessionLength(storageValue: defaults.integer(forKey: Key.defaultLength)) }
        set { defaults.set(newValue.storageValue, forKey: Key.defaultLength) }
    }
    private var wantsLidClosed: Bool {
        get { defaults.bool(forKey: Key.lidClosed) }
        set { defaults.set(newValue, forKey: Key.lidClosed) }
    }
    private var keepScreenOn: Bool {
        get { defaults.bool(forKey: Key.screenOn) }
        set { defaults.set(newValue, forKey: Key.screenOn) }
    }
    private var batteryGuard: BatteryGuard {
        get { BatteryGuard(threshold: defaults.integer(forKey: Key.battery)) }
        set { defaults.set(newValue.threshold, forKey: Key.battery) }
    }
    private var showTimeInMenuBar: Bool {
        get { defaults.bool(forKey: Key.showTime) }
        set { defaults.set(newValue, forKey: Key.showTime) }
    }
    /// Remembered on disk, so if Lamplight is force-quit with sleep switched off,
    /// the next launch switches it back on.
    private var lidEngaged: Bool {
        get { defaults.bool(forKey: Key.lidEngaged) }
        set { defaults.set(newValue, forKey: Key.lidEngaged) }
    }

    // MARK: Life cycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would share settings with the first and could switch lid sleep back on mid-session.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            exit(0)
        }
        defaults.register(defaults: [
            Key.defaultLength: SessionLength.untilStopped.storageValue,
            Key.lidClosed: true,
            Key.screenOn: true,
            Key.battery: BatteryGuard.defaultThreshold,
            Key.showTime: true
        ])
        if lidEngaged, lid.setSleepDisabled(false) {
            lidEngaged = false
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            // Left-click toggles. Right-click (or Control/Option-click) opens the menu.
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        menu.autoenablesItems = false
        installSignalHandlers()
        refreshButton()
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        // Only a plain left click toggles. Right-click, Control/Option-click, and presses that
        // don't come from the mouse (VoiceOver, keyboard access) open the menu instead.
        let event = NSApp.currentEvent
        let plainLeftClick = event?.type == .leftMouseUp
            && event?.modifierFlags.contains(.control) == false
            && event?.modifierFlags.contains(.option) == false
        if !plainLeftClick {
            showMenu()
        } else if session != nil {
            stop(note: nil)
        } else {
            start(defaultLength)
        }
    }

    /// Attaches the menu just long enough to open it, so plain clicks keep toggling.
    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        stop(note: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        checkSession()
        buildMenu()
    }

    /// Quitting from Activity Monitor or the terminal still puts sleep back the way it was.
    /// Runs on a background queue, so an open dialog on the main thread can't hold it up.
    private func installSignalHandlers() {
        signalSources = Self.makeSignalSources()
    }

    nonisolated private static func makeSignalSources() -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                let defaults = UserDefaults.standard
                if defaults.bool(forKey: lidEngagedKey), LidControl().setSleepDisabled(false) {
                    defaults.set(false, forKey: lidEngagedKey)
                }
                exit(0)
            }
            source.resume()
            return source
        }
    }

    // MARK: Sessions

    private func start(_ length: SessionLength) {
        if wantsLidClosed && !lid.isSetUp {
            offerLidSetUp()
        }
        var ignoreBattery = false
        if let battery = BatteryReader.read(),
           batteryGuard.shouldStop(onBattery: battery.onBattery, percent: battery.percent) {
            guard confirmLowBatteryStart(percent: battery.percent) else { return }
            ignoreBattery = true
        }
        sessionIgnoresBattery = ignoreBattery

        endTimer?.invalidate()
        let newSession = Session(startedAt: Date(), length: length)
        session = newSession
        lastStopNote = nil
        assertions.hold(keepScreenOn: keepScreenOn)
        applyLidSetting()

        if let end = newSession.endsAt {
            let timer = Timer(fireAt: end, interval: 0, target: self, selector: #selector(sessionTimeUp), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            endTimer = timer
        }
        if tickTimer == nil {
            let timer = Timer(timeInterval: 20, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
        refreshButton()
    }

    private func stop(note: String?) {
        endTimer?.invalidate(); endTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        let wasRunning = session != nil
        session = nil
        assertions.release()
        applyLidSetting()
        if wasRunning { lastStopNote = note }
        refreshButton()
    }

    @objc private func sessionTimeUp() {
        stop(note: "Time ran out at \(TimeText.clock(Date()))")
    }

    @objc private func tick() {
        checkSession()
        refreshButton()
    }

    private func checkSession() {
        guard let current = session else { return }
        if current.isFinished(at: Date()) {
            sessionTimeUp()
            return
        }
        if !sessionIgnoresBattery, let battery = BatteryReader.read(),
           batteryGuard.shouldStop(onBattery: battery.onBattery, percent: battery.percent) {
            stop(note: "Turned off at \(battery.percent)% battery")
        }
    }

    /// Lid sleep is switched off only while a session runs and the user wants it.
    private func applyLidSetting() {
        let wanted = session != nil && wantsLidClosed && lid.isSetUp
        guard wanted != lidEngaged else { return }
        if lid.setSleepDisabled(wanted) {
            lidEngaged = wanted
            if wanted {
                watchdog = LidControl.startWatchdog()
            } else {
                watchdog?.terminate()
                watchdog = nil
            }
        } else if wanted {
            showLidFailure()
        } else if !terminating {
            // lidEngaged stays true, so the next launch tries again; the watchdog also retries when Lamplight exits.
            showError(
                "Lid sleep is still switched off",
                "Lamplight couldn't switch it back on, so your Mac won't sleep when you close the lid. To fix it now, open Terminal and run:\n\nsudo pmset -a disablesleep 0"
            )
        }
    }

    // MARK: Menu

    private func buildMenu() {
        menu.removeAllItems()
        let now = Date()

        for line in statusLines(now: now) {
            menu.addItem(disabled(line))
        }
        menu.addItem(.separator())

        if let current = session {
            menu.addItem(item("Turn Off", #selector(turnOff), key: "t"))
            menu.addItem(lengthSubmenu("Restart For", checked: current.length))
        } else {
            let title = defaultLength == .untilStopped ? "Turn On" : "Turn On for \(defaultLength.title)"
            menu.addItem(item(title, #selector(turnOnDefault), key: "t"))
            menu.addItem(lengthSubmenu("Turn On For", checked: nil))
        }
        menu.addItem(.separator())

        let lidTitle = lid.isSetUp ? "Keep Awake with Lid Closed" : "Keep Awake with Lid Closed…"
        menu.addItem(item(lidTitle, #selector(toggleLidClosed), on: wantsLidClosed && lid.isSetUp))
        menu.addItem(item("Keep Screen On", #selector(toggleScreenOn), on: keepScreenOn))
        if BatteryReader.read() != nil {
            menu.addItem(batterySubmenu())
        }
        menu.addItem(.separator())

        menu.addItem(defaultLengthSubmenu())
        menu.addItem(item("Show Time Left in Menu Bar", #selector(toggleShowTime), on: showTimeInMenuBar))
        menu.addItem(item("Open at Login", #selector(toggleLogin), on: LoginItem.isEnabled))
        if lid.isSetUp {
            menu.addItem(item("Remove Lid-Closed Permission…", #selector(removeLidPermission)))
        }
        menu.addItem(.separator())
        menu.addItem(item("About Lamplight", #selector(showAbout)))
        menu.addItem(item("Quit Lamplight", #selector(quit), key: "q"))
    }

    private func statusLines(now: Date) -> [String] {
        guard let current = session else {
            return ["Lamplight is off", lastStopNote ?? "Your Mac sleeps as usual"]
        }
        var lines: [String]
        if let left = current.remaining(at: now), let end = current.endsAt {
            lines = ["On, \(TimeText.remaining(left))", "Turns off at \(TimeText.clock(end))"]
        } else {
            lines = ["On until you turn it off"]
        }
        if lidEngaged {
            lines.append("Stays awake with the lid closed")
        } else {
            lines.append("Closing the lid will put it to sleep")
        }
        return lines
    }

    private func lengthSubmenu(_ title: String, checked: SessionLength?) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for length in [SessionLength.untilStopped] + SessionLength.presets {
            let entry = item(length.title, #selector(turnOnFor(_:)), on: length == checked)
            entry.representedObject = length.storageValue
            sub.addItem(entry)
            if length == .untilStopped { sub.addItem(.separator()) }
        }
        parent.submenu = sub
        return parent
    }

    private func defaultLengthSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Turn On Lasts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for length in [SessionLength.untilStopped] + SessionLength.presets {
            let entry = item(length.title, #selector(setDefaultLength(_:)), on: length == defaultLength)
            entry.representedObject = length.storageValue
            sub.addItem(entry)
            if length == .untilStopped { sub.addItem(.separator()) }
        }
        parent.submenu = sub
        return parent
    }

    private func batterySubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Turn Off on Low Battery", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for threshold in BatteryGuard.choices {
            let title = threshold == 0 ? "Never" : "At \(threshold)%"
            let entry = item(title, #selector(setBatteryThreshold(_:)), on: threshold == batteryGuard.threshold)
            entry.tag = threshold
            sub.addItem(entry)
            if threshold == 0 { sub.addItem(.separator()) }
        }
        parent.submenu = sub
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "", on: Bool = false) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.state = on ? .on : .off
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func refreshButton() {
        guard let button = statusItem?.button else { return }
        let lit = session != nil
        if let shown = shownLit, shown != lit {
            animateIcon(toLit: lit)
        } else if iconAnimation == nil {
            setIcon(level: lit ? 1 : 0)
        }
        shownLit = lit
        let title: String
        if let current = session, showTimeInMenuBar, let left = current.remaining(at: Date()) {
            title = " " + TimeText.compact(left)
        } else {
            title = ""
        }
        if button.title != title { button.title = title }
        // Icon only when there's no time: an empty title still reserved space, and the menu bar
        // drew the neighbouring item (Discette) partly under the lantern.
        let position: NSControl.ImagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if button.imagePosition != position { button.imagePosition = position }
        // A square slot is exactly icon-sized, like the system's own items; widen only for the countdown.
        let length = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        if statusItem.length != length { statusItem.length = length }
        button.toolTip = lit
            ? "Lamplight is keeping your Mac awake. Click to turn off, right-click for options."
            : "Lamplight is off. Click to turn on, right-click for options."
    }

    // MARK: Icon animation

    private var shownLit: Bool?
    private var iconAnimation: Timer?
    private var animationStart = Date()
    private var animatingToLit = true

    private func setIcon(level: CGFloat) {
        guard let button = statusItem?.button else { return }
        button.image = Lantern.image(level: level)
        button.image?.accessibilityDescription = session != nil ? "Lamplight is on" : "Lamplight is off"
    }

    /// The flame catches with a small flare when turning on, and shrinks to the wick when turning off.
    private func animateIcon(toLit: Bool) {
        iconAnimation?.invalidate()
        iconAnimation = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setIcon(level: toLit ? 1 : 0)
            return
        }
        animatingToLit = toLit
        animationStart = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(animationFrame), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        iconAnimation = timer
        animationFrame()
    }

    @objc private func animationFrame() {
        let t = Date().timeIntervalSince(animationStart) / (animatingToLit ? Lantern.lightDuration : Lantern.dimDuration)
        if t >= 1 {
            iconAnimation?.invalidate()
            iconAnimation = nil
            setIcon(level: animatingToLit ? 1 : 0)
            return
        }
        setIcon(level: animatingToLit ? Lantern.lightCurve(t) : Lantern.dimCurve(t))
    }

    // MARK: Actions

    @objc private func turnOnDefault() { start(defaultLength) }

    @objc private func turnOnFor(_ sender: NSMenuItem) {
        start(SessionLength(storageValue: sender.representedObject as? Int ?? 0))
    }

    @objc private func turnOff() { stop(note: nil) }

    @objc private func toggleLidClosed() {
        if !lid.isSetUp {
            offerLidSetUp()
        } else {
            wantsLidClosed.toggle()
        }
        applyLidSetting()
        refreshButton()
    }

    @objc private func toggleScreenOn() {
        keepScreenOn.toggle()
        if session != nil { assertions.hold(keepScreenOn: keepScreenOn) }
    }

    @objc private func setBatteryThreshold(_ sender: NSMenuItem) {
        batteryGuard = BatteryGuard(threshold: sender.tag)
        sessionIgnoresBattery = false
        checkSession()
    }

    @objc private func setDefaultLength(_ sender: NSMenuItem) {
        defaultLength = SessionLength(storageValue: sender.representedObject as? Int ?? 0)
    }

    @objc private func toggleShowTime() {
        showTimeInMenuBar.toggle()
        refreshButton()
    }

    @objc private func toggleLogin() {
        if let problem = LoginItem.set(!LoginItem.isEnabled) {
            showError("Couldn't change Open at Login", problem + "\n\nThis works when Lamplight runs from the Applications folder.")
        }
    }

    @objc private func removeLidPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove the lid-closed permission?"
        alert.informativeText = "Lamplight will delete its rule from /etc/sudoers.d and your Mac will sleep when you close the lid again. You can set it up again any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if lidEngaged, lid.setSleepDisabled(false) { lidEngaged = false }
        switch lid.remove() {
        case .done:
            lidEngaged = false
            wantsLidClosed = false
        case .cancelled:
            break
        case .failed(let message):
            showError("Couldn't remove the permission", message)
        }
        applyLidSetting()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "Keeps your Mac awake, lid open or closed.\nFree and open source under the MIT License.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(
            string: "github.com/Wu-Adam1234/lamplight",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: Self.repoURL]
        ))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Dialogs

    private func offerLidSetUp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stay awake with the lid closed?"
        alert.informativeText = """
        macOS puts a laptop to sleep when the lid closes, even while apps ask it to stay awake. \
        Lamplight can switch that off while it's on, and switch it back the moment it turns off.

        This needs your administrator password once. Lamplight adds one rule that lets it run a single \
        command without asking again: pmset disablesleep, on or off. Nothing else. \
        You can remove it from the menu any time.
        """
        alert.addButton(withTitle: "Allow…")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            wantsLidClosed = false
            return
        }
        switch lid.setUp() {
        case .done:
            wantsLidClosed = true
        case .cancelled:
            wantsLidClosed = false
        case .failed(let message):
            wantsLidClosed = false
            showError("Couldn't set up lid-closed mode", message)
        }
    }

    private func confirmLowBatteryStart(percent: Int) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Battery is at \(percent)%"
        alert.informativeText = "Lamplight normally turns off at \(batteryGuard.threshold)%. Turn it on anyway? It will ignore the battery cutoff until you turn it off."
        alert.addButton(withTitle: "Turn On Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showLidFailure() {
        showError(
            "Lid-closed mode didn't switch on",
            "Your Mac will still sleep if you close the lid. The permission may have been removed. Choose “Keep Awake with Lid Closed…” to set it up again."
        )
    }

    private func showError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Menu bar icon

/// The lantern, drawn in code as a template image so it follows light and dark menu bars.
enum Lantern {
    static let lightDuration = 0.45
    static let dimDuration = 0.3

    /// Turning on: the flame catches, flares a little past full, then settles.
    static func lightCurve(_ t: Double) -> CGFloat {
        let c1 = 1.9, c3 = c1 + 1, u = t - 1
        return CGFloat(1 + c3 * u * u * u + c1 * u * u)
    }

    /// Turning off: the flame shrinks back into the wick, quickly at the end.
    static func dimCurve(_ t: Double) -> CGFloat {
        CGFloat(1 - t * t)
    }

    /// level 0 is off (just the wick), 1 is fully lit; values a little above 1 are the flare.
    static func image(level: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(level: level, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws the lantern on an 18 x 18 grid in the current graphics context.
    static func draw(level: CGFloat, color: NSColor) {
        color.setStroke()
        color.setFill()

        // Handle
        let handle = NSBezierPath(ovalIn: NSRect(x: 6.6, y: 13.4, width: 4.8, height: 4.0))
        handle.lineWidth = 1.2
        handle.stroke()

        // Cap
        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: 4.8, y: 12.4))
        cap.line(to: NSPoint(x: 13.2, y: 12.4))
        cap.line(to: NSPoint(x: 11.4, y: 14.6))
        cap.line(to: NSPoint(x: 6.6, y: 14.6))
        cap.close()
        cap.fill()

        // Glass, filling with light as the flame grows
        let glassRect = NSRect(x: 5.6, y: 4.3, width: 6.8, height: 8.2)
        let glow = min(max(level, 0), 1)
        if glow > 0 {
            color.withAlphaComponent(0.3 * glow).setFill()
            NSBezierPath(roundedRect: glassRect, xRadius: 1.6, yRadius: 1.6).fill()
            color.setFill()
        }
        let glass = NSBezierPath(roundedRect: glassRect.insetBy(dx: 0.6, dy: 0.6), xRadius: 1.2, yRadius: 1.2)
        glass.lineWidth = 1.2
        glass.stroke()

        // Base
        NSBezierPath(roundedRect: NSRect(x: 4.4, y: 2.2, width: 9.2, height: 2.1), xRadius: 0.9, yRadius: 0.9).fill()

        // Wick, then the flame on top of it
        NSBezierPath(roundedRect: NSRect(x: 8.4, y: 5.4, width: 1.2, height: 1.8), xRadius: 0.5, yRadius: 0.5).fill()
        if level > 0.03 {
            let height = 5.4 * level
            let width = 1.9 * (0.55 + 0.45 * min(level, 1))
            flame(centerX: 9, bottom: 5.6, top: 5.6 + height, halfWidth: width).fill()
        }
    }

    static func flame(centerX x: CGFloat, bottom: CGFloat, top: CGFloat, halfWidth w: CGFloat) -> NSBezierPath {
        let h = top - bottom
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: top))
        path.curve(to: NSPoint(x: x + w, y: bottom + h * 0.3),
                   controlPoint1: NSPoint(x: x + w * 0.25, y: bottom + h * 0.78),
                   controlPoint2: NSPoint(x: x + w, y: bottom + h * 0.58))
        path.curve(to: NSPoint(x: x, y: bottom),
                   controlPoint1: NSPoint(x: x + w, y: bottom + h * 0.1),
                   controlPoint2: NSPoint(x: x + w * 0.55, y: bottom))
        path.curve(to: NSPoint(x: x - w, y: bottom + h * 0.3),
                   controlPoint1: NSPoint(x: x - w * 0.55, y: bottom),
                   controlPoint2: NSPoint(x: x - w, y: bottom + h * 0.1))
        path.curve(to: NSPoint(x: x, y: top),
                   controlPoint1: NSPoint(x: x - w, y: bottom + h * 0.58),
                   controlPoint2: NSPoint(x: x - w * 0.25, y: bottom + h * 0.78))
        path.close()
        return path
    }
}
