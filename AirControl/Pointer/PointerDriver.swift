import AppKit
import CoreGraphics

/// Posts real mouse, scroll and keyboard events. Needs Accessibility permission; without it the
/// system silently drops them.
final class PointerDriver {
    /// Stamped on every event we post, so the app can tell its own pointer moves from the real mouse.
    static let eventTag: Int64 = 0x41_49_52   // "AIR"

    /// The source's user data is copied into each event it creates (eventSourceUserData).
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        // Don't mute the real mouse and trackpad for a moment after each synthetic event.
        s?.localEventsSuppressionInterval = 0
        s?.userData = PointerDriver.eventTag
        return s
    }()

    /// Where we last put the pointer, to tell our moves from the physical mouse's.
    private(set) var lastPosted: CGPoint?
    private(set) var buttonDown = false

    // MARK: Pointer

    func move(to p: CGPoint) {
        post(buttonDown ? .leftMouseDragged : .mouseMoved, at: p, button: .left)
        lastPosted = p
    }

    func click(at p: CGPoint, count: Int = 1) {
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        if shiftHeld {
            down?.flags.insert(.maskShift)
            up?.flags.insert(.maskShift)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        lastPosted = p
    }

    func rightClick(at p: CGPoint) {
        post(.rightMouseDown, at: p, button: .right)
        post(.rightMouseUp, at: p, button: .right)
        lastPosted = p
    }

    func mouseDown(at p: CGPoint) {
        post(.leftMouseDown, at: p, button: .left)
        buttonDown = true
        lastPosted = p
    }

    func mouseUp(at p: CGPoint) {
        guard buttonDown else { return }
        post(.leftMouseUp, at: p, button: .left)
        buttonDown = false
        lastPosted = p
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        if shiftHeld { e?.flags.insert(.maskShift) }
        e?.post(tap: .cghidEventTap)
    }

    // MARK: Held modifier (the other hand's pinch)

    private(set) var shiftHeld = false

    /// Holds Shift down for the pointer hand's clicks and drags, like keeping a finger on the key.
    func setShiftHeld(_ on: Bool) {
        guard on != shiftHeld else { return }
        shiftHeld = on
        let e = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: on)   // left Shift
        e?.flags = on ? .maskShift : []
        e?.post(tap: .cghidEventTap)
    }

    // MARK: Trackpad pinch and rotate

    /// Real trackpads wrap pinch and rotate in a gesture envelope and tag each event with a phase,
    /// which is what lets apps zoom smoothly around the pointer. These are the (undocumented but
    /// long-stable) CGEvent fields the system uses for them.
    enum GesturePhase: Int64 {
        case began = 1, changed = 2, ended = 4
    }
    private enum GestureSubtype: Int64 {
        case rotate = 5, magnify = 8, begin = 61, end = 62
    }
    private static let gestureEventType = CGEventType(rawValue: 29)          // NSEventTypeGesture
    private static let gestureSubtypeField = CGEventField(rawValue: 110)
    private static let magnificationField = CGEventField(rawValue: 113)
    private static let rotationField = CGEventField(rawValue: 114)
    private static let gesturePhaseField = CGEventField(rawValue: 132)
    private var openGestures = 0

    /// `amount` is the change in magnification: 0.05 = 5% bigger.
    func magnify(_ amount: CGFloat, phase: GesturePhase, at p: CGPoint) {
        postGesture(.magnify, phase: phase, at: p) { e in
            if let f = Self.magnificationField { e.setDoubleValueField(f, value: Double(amount)) }
        }
    }

    /// Degrees, counterclockwise positive.
    func rotate(_ degrees: CGFloat, phase: GesturePhase, at p: CGPoint) {
        postGesture(.rotate, phase: phase, at: p) { e in
            if let f = Self.rotationField { e.setDoubleValueField(f, value: Double(degrees)) }
        }
    }

    private func postGesture(_ subtype: GestureSubtype, phase: GesturePhase, at p: CGPoint, configure: (CGEvent) -> Void) {
        if phase == .began {
            if openGestures == 0 { makeGesture(.begin, at: p)?.post(tap: .cghidEventTap) }
            openGestures += 1
        }
        if let e = makeGesture(subtype, at: p) {
            if let f = Self.gesturePhaseField { e.setIntegerValueField(f, value: phase.rawValue) }
            configure(e)
            e.post(tap: .cghidEventTap)
        }
        if phase == .ended {
            openGestures = max(0, openGestures - 1)
            if openGestures == 0 { makeGesture(.end, at: p)?.post(tap: .cghidEventTap) }
        }
    }

    private func makeGesture(_ subtype: GestureSubtype, at p: CGPoint) -> CGEvent? {
        guard let type = Self.gestureEventType, let e = CGEvent(source: source) else { return nil }
        e.type = type
        e.location = p
        if let f = Self.gestureSubtypeField { e.setIntegerValueField(f, value: subtype.rawValue) }
        return e
    }

    // MARK: Zoom fallbacks

    private var zoomAccumulator: CGFloat = 0

    /// ⌘ + scroll wheel: zoom in design tools, whiteboards and canvas web apps.
    func commandScrollZoom(_ amount: CGFloat, at p: CGPoint) {
        zoomAccumulator += log(1 + amount) * 400
        let px = Int32(zoomAccumulator.rounded(.towardZero))
        guard px != 0,
              let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                              wheel1: px, wheel2: 0, wheel3: 0) else { return }
        zoomAccumulator -= CGFloat(px)
        e.location = p
        e.flags = .maskCommand
        e.post(tap: .cghidEventTap)
    }

    /// ⌘= / ⌘− in 25% steps.
    func keyboardZoom(_ amount: CGFloat) {
        zoomAccumulator += log(1 + amount)
        let step: CGFloat = log(1.25)
        while zoomAccumulator > step {
            press(24, flags: .maskCommand)    // ⌘=
            zoomAccumulator -= step
        }
        while zoomAccumulator < -step {
            press(27, flags: .maskCommand)    // ⌘−
            zoomAccumulator += step
        }
    }

    func resetZoom() {
        zoomAccumulator = 0
    }

    // MARK: Scrolling

    /// Trackpad-style scroll phases, so apps rubber-band and snap like they do for real gestures.
    private enum Phase: Int64 {
        case none = 0, began = 1, changed = 2, ended = 4
    }
    private enum Momentum: Int64 {
        case none = 0, began = 1, changed = 2, ended = 3
    }
    private static let scrollPhaseField = CGEventField(rawValue: 99)
    private static let momentumPhaseField = CGEventField(rawValue: 123)

    private var remainder = CGPoint.zero
    private var velocity = CGPoint.zero
    private var momentumActive = false
    private var momentumStarted = false
    private var scrollPoint = CGPoint.zero
    /// 1 = content follows the hand (like touch), -1 = reversed.
    var direction: CGFloat = 1
    var gain: CGFloat = 1.6

    func scrollBegan(at p: CGPoint) {
        stopMomentum()
        scrollPoint = p
        remainder = .zero
        postScroll(dx: 0, dy: 0, phase: .began, momentum: .none)
    }

    /// Hand movement in points; positive y = hand moved down.
    func scroll(dx: CGFloat, dy: CGFloat) {
        postScroll(dx: dx * gain * direction, dy: dy * gain * direction, phase: .changed, momentum: .none)
    }

    /// Hand velocity at release, points per second.
    func scrollEnded(vx: CGFloat, vy: CGFloat) {
        postScroll(dx: 0, dy: 0, phase: .ended, momentum: .none)
        let v = CGPoint(x: vx * gain * direction, y: vy * gain * direction)
        guard hypot(v.x, v.y) > 150 else { return }
        velocity = CGPoint(x: min(max(v.x, -6000), 6000), y: min(max(v.y, -6000), 6000))
        momentumActive = true
        momentumStarted = false
    }

    /// Call every display frame; carries a flick on with decaying speed.
    func tick(dt: CGFloat) {
        guard momentumActive else { return }
        let decay = pow(0.996, dt * 1000)
        velocity.x *= decay
        velocity.y *= decay
        if hypot(velocity.x, velocity.y) < 25 {
            postScroll(dx: 0, dy: 0, phase: .none, momentum: .ended)
            momentumActive = false
            return
        }
        postScroll(dx: velocity.x * dt, dy: velocity.y * dt, phase: .none,
                   momentum: momentumStarted ? .changed : .began)
        momentumStarted = true
    }

    func stopMomentum() {
        guard momentumActive else { return }
        postScroll(dx: 0, dy: 0, phase: .none, momentum: .ended)
        momentumActive = false
    }

    private func postScroll(dx: CGFloat, dy: CGFloat, phase: Phase, momentum: Momentum) {
        // Wheel deltas: positive = reveal content above/left. Hand down (dy > 0) drags content down.
        let total = CGPoint(x: dx + remainder.x, y: dy + remainder.y)
        let wy = Int32(total.y.rounded(.towardZero))
        let wx = Int32(total.x.rounded(.towardZero))
        remainder = CGPoint(x: total.x - CGFloat(wx), y: total.y - CGFloat(wy))
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: wy, wheel2: wx, wheel3: 0) else { return }
        e.location = scrollPoint
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let f = Self.scrollPhaseField { e.setIntegerValueField(f, value: phase.rawValue) }
        if let f = Self.momentumPhaseField { e.setIntegerValueField(f, value: momentum.rawValue) }
        e.post(tap: .cghidEventTap)
    }

    /// A plain scroll by a fixed amount (voice: "scroll down").
    func scrollBy(dx: CGFloat, dy: CGFloat, at p: CGPoint) {
        scrollPoint = p
        remainder = .zero
        // A short trackpad-like flick reads naturally in every app.
        postScroll(dx: 0, dy: 0, phase: .began, momentum: .none)
        let steps = 8
        for _ in 0..<steps { postScroll(dx: dx / CGFloat(steps), dy: dy / CGFloat(steps), phase: .changed, momentum: .none) }
        postScroll(dx: 0, dy: 0, phase: .ended, momentum: .none)
    }

    // MARK: Keyboard

    func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Types arbitrary text (any language, emoji) into whatever has keyboard focus.
    func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            i += 16
            for keyDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                chunk.withUnsafeBufferPointer { buf in
                    e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

/// Hides the arrow pointer while the hand cursor is up, so the glass cursor can morph into the
/// control it snaps to — the iPadOS pointer look. A background app can only hide the cursor after
/// opting in through a private WindowServer property; if that isn't available, the arrow simply
/// stays visible under the glass cursor.
enum SystemCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static var hidden = false

    private static let allowed: Bool = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return false }
        let conn = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let set = unsafeBitCast(setSym, to: SetProperty.self)
        return set(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    static var canHide: Bool { allowed }

    static func setHidden(_ hide: Bool) {
        guard hide != hidden else { return }
        if hide {
            guard allowed else { return }
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        hidden = hide
    }
}

/// Virtual key codes (ANSI layout) for the keys voice commands can press.
enum KeyCode {
    static let returnKey: CGKeyCode = 36
    static let tab: CGKeyCode = 48
    static let space: CGKeyCode = 49
    static let delete: CGKeyCode = 51
    static let escape: CGKeyCode = 53
    static let forwardDelete: CGKeyCode = 117
    static let home: CGKeyCode = 115
    static let end: CGKeyCode = 119
    static let pageUp: CGKeyCode = 116
    static let pageDown: CGKeyCode = 121
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126

    static let letters: [Character: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40,
        "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
        "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29
    ]

    static let named: [String: CGKeyCode] = [
        "return": returnKey, "enter": returnKey, "tab": tab, "space": space, "spacebar": space,
        "delete": delete, "backspace": delete, "escape": escape, "esc": escape,
        "forward delete": forwardDelete, "home": home, "end": end, "page up": pageUp, "page down": pageDown,
        "left": left, "right": right, "up": up, "down": down,
        "left arrow": left, "right arrow": right, "up arrow": up, "down arrow": down,
        "comma": 43, "period": 47, "dot": 47, "slash": 44, "minus": 27, "dash": 27, "equals": 24, "plus": 24,
        "left bracket": 33, "right bracket": 30, "semicolon": 41, "quote": 39, "backslash": 42,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    static func code(for name: String) -> CGKeyCode? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = named[n] { return c }
        if n.count == 1, let ch = n.first, let c = letters[ch] { return c }
        // Spoken letters: "letter t", "the letter t".
        if n.hasPrefix("letter "), let ch = n.dropFirst(7).first, let c = letters[ch] { return c }
        return nil
    }

    static let modifiers: [String: CGEventFlags] = [
        "command": .maskCommand, "cmd": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate, "alt": .maskAlternate,
        "control": .maskControl, "ctrl": .maskControl,
        "function": .maskSecondaryFn, "fn": .maskSecondaryFn
    ]
}
