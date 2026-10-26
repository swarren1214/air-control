import AppKit
import ApplicationServices

/// Everything a Mac trackpad gesture does that isn't a click, scroll or pinch, plus the window
/// controls. Gestures, the window menu and voice all go through `CommandRunner.perform`.
enum SystemAction: Equatable {
    // Swipes
    case back, forward
    case nextSpace, previousSpace, missionControl, appWindows
    case showDesktop, apps, notificationCenter
    // Point and click
    case lookUp, smartZoom
    // Windows (the one under the pointer)
    case closeWindow, minimizeWindow, fullScreenWindow, tileLeft, tileRight, fillWindow

    var title: String {
        switch self {
        case .back: return "Back"
        case .forward: return "Forward"
        case .nextSpace: return "Next space"
        case .previousSpace: return "Previous space"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows"
        case .showDesktop: return "Desktop"
        case .apps: return "Apps"
        case .notificationCenter: return "Notification Center"
        case .lookUp: return "Look Up"
        case .smartZoom: return "Smart zoom"
        case .closeWindow: return "Closed window"
        case .minimizeWindow: return "Minimized"
        case .fullScreenWindow: return "Full screen"
        case .tileLeft: return "Tiled left"
        case .tileRight: return "Tiled right"
        case .fillWindow: return "Filled screen"
        }
    }

    var isWindowAction: Bool {
        switch self {
        case .closeWindow, .minimizeWindow, .fullScreenWindow, .tileLeft, .tileRight, .fillWindow: return true
        default: return false
        }
    }
}

extension CommandRunner {
    /// `point`: where the gesture happened (defaults to the pointer). Window actions act on the
    /// window under it, falling back to the front window.
    func perform(_ action: SystemAction, at point: CGPoint? = nil) {
        let p = point ?? pointer()
        switch action {
        case .back: run(.shortcut(.goBack))
        case .forward: run(.shortcut(.goForward))
        case .nextSpace: run(.shortcut(.nextSpace))
        case .previousSpace: run(.shortcut(.previousSpace))
        case .missionControl: run(.shortcut(.missionControl))
        case .appWindows: run(.shortcut(.appWindows))
        case .showDesktop: run(.shortcut(.showDesktop))
        case .apps: openApps()
        case .notificationCenter: openNotificationCenter()
        case .lookUp:
            driver.press(2, flags: [.maskCommand, .maskControl])   // ⌃⌘D: Look Up at the pointer
            toast(action.title)
        case .smartZoom:
            driver.smartMagnify(at: p)
            toast(action.title)
        case .closeWindow, .minimizeWindow, .fullScreenWindow, .tileLeft, .tileRight, .fillWindow:
            window(action, at: p)
        }
    }

    /// Launchpad became the Apps view in macOS 26; older systems still have Launchpad.
    private func openApps() {
        let candidates = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            toast("Apps")
        } else {
            driver.press(KeyCode.space, flags: .maskCommand)
            toast("Spotlight")
        }
    }

    /// There's no shortcut for Notification Center, so press the menu bar clock, like a click would.
    private func openNotificationCenter() {
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            toast("Couldn’t open Notification Center")
            return
        }
        let pid = cc.processIdentifier
        let toast = self.toast
        AX.queue.async {
            let bar = AXElement.application(pid: pid).element("AXExtrasMenuBar")
            let clock = bar?.children.first { ($0.attribute("AXIdentifier") as String?) == "com.apple.menuextra.clock" }
            let ok = clock?.press() ?? false
            DispatchQueue.main.async { toast(ok ? "Notification Center" : "Couldn’t open Notification Center") }
        }
    }

    private func window(_ action: SystemAction, at p: CGPoint) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Visible frames (minus menu bar and Dock) in the global top-left space AX uses.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens: [(frame: CGRect, visible: CGRect)] = NSScreen.screens.map { s in
            let v = s.visibleFrame
            return (Displays.globalFrame(of: s), CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height))
        }
        let toast = self.toast
        AX.queue.async {
            guard let win = CommandRunner.window(at: p, frontPID: front) else {
                DispatchQueue.main.async { toast("No window there") }
                return
            }
            var done = false
            switch action {
            case .closeWindow:
                done = win.element(kAXCloseButtonAttribute)?.press() ?? false
            case .minimizeWindow:
                done = win.set(kAXMinimizedAttribute, kCFBooleanTrue)
                if !done { done = win.element(kAXMinimizeButtonAttribute)?.press() ?? false }
            case .fullScreenWindow:
                let on: Bool = win.attribute("AXFullScreen") ?? false
                done = win.set("AXFullScreen", on ? kCFBooleanFalse : kCFBooleanTrue)
                if !done { done = win.element(kAXFullScreenButtonAttribute)?.press() ?? false }
            case .tileLeft, .tileRight, .fillWindow:
                let f = win.frame ?? .zero
                guard let screen = screens.first(where: { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) }) ?? screens.first else { break }
                var r = screen.visible
                if action == .tileLeft { r.size.width = (r.width / 2).rounded() }
                if action == .tileRight {
                    r.origin.x += (r.width / 2).rounded()
                    r.size.width -= (r.width / 2).rounded()
                }
                win.perform(kAXRaiseAction)
                done = win.setFrame(r)
            default:
                break
            }
            let pid = win.pid
            DispatchQueue.main.async {
                if done, action == .tileLeft || action == .tileRight || action == .fillWindow {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                toast(done ? action.title : "That window can’t do that")
            }
        }
    }

    /// The window under a point, or the front app's window. Call on `AX.queue`.
    static func window(at p: CGPoint, frontPID: pid_t?) -> AXElement? {
        let own = ProcessInfo.processInfo.processIdentifier
        if var el = AXElement.at(p), el.pid != own {
            if let w = el.element(kAXWindowAttribute) { return w }
            for _ in 0..<40 {
                if el.role == kAXWindowRole { return el }
                guard let up = el.parent else { break }
                el = up
            }
        }
        guard let pid = frontPID, pid != own else { return nil }
        let app = AXElement.application(pid: pid)
        return app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute)
    }
}
