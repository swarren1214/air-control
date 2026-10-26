import AppKit
import ApplicationServices

/// Small, typed wrapper over the Accessibility C API. All calls are synchronous IPC into other
/// apps, so they run on the `AX.queue` background queue, never the main thread.
struct AXElement {
    let ref: AXUIElement

    static let systemWide = AXElement(ref: AXUIElementCreateSystemWide())

    static func application(pid: pid_t) -> AXElement {
        AXElement(ref: AXUIElementCreateApplication(pid))
    }

    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func element(_ name: String) -> AXElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXElement(ref: v as! AXUIElement)
    }

    func elements(_ name: String) -> [AXElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? AXElement(ref: item as! AXUIElement) : nil
        }
    }

    var role: String? { attribute(kAXRoleAttribute) }
    var subrole: String? { attribute(kAXSubroleAttribute) }
    var parent: AXElement? { element(kAXParentAttribute) }
    var children: [AXElement] { elements(kAXChildrenAttribute) }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(ref, &p)
        return p
    }

    /// Global frame, top-left origin (same space as CGEvent locations).
    var frame: CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(ref, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let pv = posValue, let sv = sizeValue,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    var isEnabled: Bool { (attribute(kAXEnabledAttribute) as Bool?) ?? true }

    /// What a person would call this control: its title, description, or text value.
    var label: String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let s: String = attribute(key) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, t.count <= 80 { return t }
            }
        }
        // Links and many web buttons keep their text in a child.
        for child in children.prefix(3) {
            if let s = (child.attribute(kAXValueAttribute) as String?) ?? (child.attribute(kAXTitleAttribute) as String?) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, t.count <= 80 { return t }
            }
        }
        return nil
    }

    func press() -> Bool {
        AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success
    }

    static func at(_ point: CGPoint) -> AXElement? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide.ref, Float(point.x), Float(point.y), &found) == .success,
              let el = found else { return nil }
        return AXElement(ref: el)
    }
}

enum AX {
    static let queue = DispatchQueue(label: "aircontrol.ax", qos: .userInteractive)

    /// Roles that are things you click. Big containers (rows, web areas, groups) are excluded so
    /// the cursor only snaps to controls, like the iPadOS pointer.
    static let pressableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
        "AXDockItem", "AXComboBox", "AXSegment", "AXTab"
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func configureTimeouts() {
        // A hung app must never stall the cursor.
        AXUIElementSetMessagingTimeout(AXElement.systemWide.ref, 0.08)
    }

    static func isPressable(_ el: AXElement) -> Bool {
        guard let role = el.role else { return false }
        if pressableRoles.contains(role) { return true }
        if role == "AXImage" || role == "AXStaticText" || role == "AXGroup" || role == "AXCell" {
            return el.actions.contains(kAXPressAction as String)
        }
        return false
    }

    /// Size limits for a snap target: big things are content, not controls.
    static func isSnapSized(_ r: CGRect) -> Bool {
        r.width >= 8 && r.height >= 8 && r.width <= 520 && r.height <= 110
    }
}

/// Something the cursor can snap to.
struct SnapTarget: Equatable {
    var frame: CGRect
    var role: String
    var label: String?
    var pid: pid_t

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var cornerRadius: CGFloat {
        switch role {
        case "AXCheckBox", "AXRadioButton", "AXDockItem": return min(frame.width, frame.height) / 2 + 4
        default: return min(10, frame.height / 2 + 3)
        }
    }
}

/// Finds the control under (or right next to) the hand cursor, off the main thread. Only the most
/// recent request is ever processed, so a slow app can't build a backlog.
final class Snapper {
    /// Called on the main queue with the queried point and what's there.
    var onResult: ((CGPoint, SnapTarget?) -> Void)?
    /// Pull distance for magnetism: a control this close (in points) still captures the cursor.
    var magnetRange: CGFloat = 16

    private var busy = false
    private var pending: CGPoint?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func query(_ point: CGPoint) {
        pending = point
        guard !busy else { return }
        runNext()
    }

    private func runNext() {
        guard let p = pending else {
            busy = false
            return
        }
        pending = nil
        busy = true
        let range = magnetRange
        let own = ownPID
        AX.queue.async { [weak self] in
            var result = Self.target(at: p, ownPID: own)
            if result == nil {
                // Magnetism: look a little way out in each direction and take the closest control.
                let offsets = [CGPoint(x: range, y: 0), CGPoint(x: -range, y: 0),
                               CGPoint(x: 0, y: range), CGPoint(x: 0, y: -range)]
                var best: (SnapTarget, CGFloat)?
                for o in offsets {
                    guard let t = Self.target(at: CGPoint(x: p.x + o.x, y: p.y + o.y), ownPID: own) else { continue }
                    let d = Self.distance(from: p, to: t.frame)
                    if d <= range, best == nil || d < best!.1 { best = (t, d) }
                }
                result = best?.0
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.onResult?(p, result)
                self.runNext()
            }
        }
    }

    static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// The pressable control at a point: the element itself or one of its close ancestors.
    static func target(at p: CGPoint, ownPID: pid_t) -> SnapTarget? {
        guard var el = AXElement.at(p), el.pid != ownPID else { return nil }
        for _ in 0..<5 {
            if AX.isPressable(el), el.isEnabled, let frame = el.frame, AX.isSnapSized(frame) {
                return SnapTarget(frame: frame, role: el.role ?? "", label: el.label, pid: el.pid)
            }
            guard let up = el.parent else { break }
            el = up
        }
        return nil
    }
}

/// Reads the frontmost window for voice commands: "click Send" and the on-device model's context.
enum ScreenReader {
    struct Control {
        var label: String
        var frame: CGRect
        var element: AXElement
    }

    struct Snapshot {
        var appName: String
        var windowTitle: String?
        var controls: [Control]
    }

    /// What `snapshot` needs from AppKit, read on the main thread.
    struct Target {
        var pid: pid_t
        var appName: String
        var screens: [CGRect]

        /// Call on the main thread.
        static func current() -> Target? {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return Target(pid: app.processIdentifier, appName: app.localizedName ?? "this app",
                          screens: NSScreen.screens.map { Displays.globalFrame(of: $0) })
        }
    }

    /// Walks the frontmost app's focused window (and its menu bar) for labelled controls.
    /// Call on `AX.queue`, with a `Target` read on the main thread.
    static func snapshot(of target: Target?, limit: Int = 4000) -> Snapshot? {
        guard let target else { return nil }
        let axApp = AXElement.application(pid: target.pid)
        AXUIElementSetMessagingTimeout(axApp.ref, 0.15)
        let window = axApp.element(kAXFocusedWindowAttribute) ?? axApp.element(kAXMainWindowAttribute)
        var controls: [Control] = []
        var queue: [AXElement] = []
        if let window { queue.append(window) }
        var visited = 0
        let screens = target.screens
        while !queue.isEmpty, visited < limit {
            let el = queue.removeFirst()
            visited += 1
            if AX.isPressable(el), let label = el.label, let frame = el.frame,
               frame.width > 2, frame.height > 2, screens.contains(where: { $0.intersects(frame) }) {
                controls.append(Control(label: label, frame: frame, element: el))
            }
            queue.append(contentsOf: el.children)
        }
        // Menu bar titles ("File", "Edit", …) so "click View" works too.
        if let bar = axApp.element(kAXMenuBarAttribute) {
            for item in bar.children {
                if let label = item.label, let frame = item.frame {
                    controls.append(Control(label: label, frame: frame, element: item))
                }
            }
        }
        let title: String? = window?.attribute(kAXTitleAttribute)
        return Snapshot(appName: target.appName, windowTitle: title, controls: controls)
    }

    /// Best control for a spoken name: exact, then prefix, then contains, then shared words.
    static func find(_ spoken: String, in snapshot: Snapshot) -> Control? {
        let wanted = normalize(spoken)
        guard !wanted.isEmpty else { return nil }
        let wantedWords = Set(wanted.split(separator: " "))
        var best: (Control, Int)?
        for c in snapshot.controls {
            let label = normalize(c.label)
            guard !label.isEmpty else { continue }
            var score = 0
            if label == wanted { score = 100 }
            else if label.hasPrefix(wanted) || wanted.hasPrefix(label) { score = 70 }
            else if label.contains(wanted) { score = 55 }
            else {
                let overlap = wantedWords.intersection(label.split(separator: " ")).count
                if overlap > 0 { score = 20 + 15 * overlap }
            }
            // Prefer shorter labels for equal scores ("Send" over "Send Later").
            score -= min(label.count / 10, 5)
            if score > 0, best == nil || score > best!.1 { best = (c, score) }
        }
        guard let found = best, found.1 >= 30 else { return nil }
        return found.0
    }

    static func normalize(_ s: String) -> String {
        let cleaned = String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").joined(separator: " ")
    }
}
