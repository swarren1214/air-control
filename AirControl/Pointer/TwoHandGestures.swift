import CoreGraphics
import Foundation
import Observation

/// How a two-hand pinch zooms the app under the pointer.
enum TwoHandZoomMode: String, CaseIterable, Identifiable {
    /// Synthesized trackpad pinch and rotate events: apps zoom and rotate exactly as they do for a trackpad.
    case trackpad
    /// ⌘ + scroll, which most design and whiteboard apps (and canvas web apps) treat as zoom.
    case commandScroll
    /// ⌘+ and ⌘−, the menu shortcuts nearly every Mac app has. Steps rather than glides.
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: return "Trackpad pinch"
        case .commandScroll: return "⌘ + scroll"
        case .keyboard: return "⌘+ / ⌘−"
        }
    }
}

enum TwoHandSwipe {
    case left, right, up, down
    /// Open palms pulled apart (Show Desktop) or pushed together (Apps), like spreading or pinching
    /// thumb and three fingers on a trackpad.
    case apart, together
}

/// Gestures that need both hands, layered on top of the one-hand pointer:
///
/// - pinch with both hands at once, then spread or close → zoom in or out at the pointer
/// - …twist (like turning a steering wheel) → rotate
/// - …move both hands together → pan, with momentum when you let go
/// - hold the other hand in a pinch on its own → Shift is held, so pointer-hand clicks add to a
///   selection and drags keep proportions or snap to angles
/// - swipe both hands left / right → next / previous Space; up → Mission Control; down → app windows
///   (the four-finger trackpad swipes)
/// - pull open palms apart → Show Desktop; push them together → Apps
/// - a quick pinch-and-release with both hands → smart zoom (the two-finger double tap)
///
/// Zoom, rotate and pan each wait for a clear movement before they kick in, the way a trackpad
/// does, so a zoom doesn't accidentally rotate a shape and a rotation doesn't pan the canvas.
@Observable
final class TwoHandGestures {
    enum Phase: Equatable {
        case idle
        /// Both hands pinched: zooming, rotating and panning.
        case manipulating
        /// The other hand is pinched on its own: Shift is down.
        case modifier
    }

    // MARK: Tunables
    /// The two pinches must start this close together to count as a two-hand pinch.
    var onsetWindow: TimeInterval = 0.45
    /// The other hand must stay pinched this long, alone, to hold Shift.
    var modifierDelay: TimeInterval = 0.45
    /// Bridges the other hand dropping out of a frame or two.
    var partnerGrace: TimeInterval = 0.25
    /// Change in hand separation (log ratio, ≈ 7%) before zoom starts.
    var zoomDeadband: CGFloat = 0.07
    /// Twist (radians, ≈ 12°) before rotation starts.
    var rotateDeadband: CGFloat = 0.21
    /// Screen points the midpoint must move before panning starts.
    var panDeadband: CGFloat = 30
    /// > 1 zooms more than the hands spread.
    var zoomGain: CGFloat = 1.4
    /// Palm lengths per second and palm lengths of travel for a swipe.
    var swipeSpeed: CGFloat = 5.5
    var swipeTravel: CGFloat = 1.6
    var swipeCooldown: TimeInterval = 1.0
    var swipesEnabled = true

    // MARK: Observable state
    private(set) var phase: Phase = .idle
    private(set) var zooming = false
    private(set) var rotating = false
    private(set) var panning = false
    /// Pointer hand → other hand, in screen points, for drawing the two hands on screen.
    private(set) var spread: CGPoint = .zero
    /// Zoom since the gesture started (1 = unchanged).
    private(set) var scale: CGFloat = 1
    /// Rotation since the gesture started, degrees, counterclockwise positive.
    private(set) var rotation: CGFloat = 0

    // MARK: Callbacks
    @ObservationIgnored var onZoomBegan: (() -> Void)?
    /// Magnification change: 0.05 = 5% bigger than a moment ago.
    @ObservationIgnored var onZoom: ((CGFloat) -> Void)?
    @ObservationIgnored var onZoomEnded: (() -> Void)?
    @ObservationIgnored var onRotateBegan: (() -> Void)?
    /// Degrees, counterclockwise positive (the trackpad convention).
    @ObservationIgnored var onRotate: ((CGFloat) -> Void)?
    @ObservationIgnored var onRotateEnded: (() -> Void)?
    @ObservationIgnored var onPanBegan: (() -> Void)?
    /// Screen points the hands moved since the last frame.
    @ObservationIgnored var onPan: ((CGFloat, CGFloat) -> Void)?
    /// Release velocity, points per second.
    @ObservationIgnored var onPanEnded: ((CGFloat, CGFloat) -> Void)?
    @ObservationIgnored var onModifier: ((Bool) -> Void)?
    @ObservationIgnored var onSwipe: ((TwoHandSwipe) -> Void)?
    /// Both hands pinched and released quickly without moving.
    @ObservationIgnored var onTap: (() -> Void)?

    // MARK: Private
    @ObservationIgnored private var ownerPinch = PinchLatch()
    @ObservationIgnored private var partnerPinch = PinchLatch()
    @ObservationIgnored private var lastPartner: HandFrame?
    @ObservationIgnored private var partnerLostAt: TimeInterval?
    /// After a gesture, nothing new starts until both hands have opened.
    @ObservationIgnored private var quietUntilOpen = false
    @ObservationIgnored private var aspect: CGFloat = 16.0 / 9.0
    @ObservationIgnored private var now: TimeInterval = 0
    @ObservationIgnored private var beganAt: TimeInterval = 0

    @ObservationIgnored private var startLength: CGFloat = 1
    @ObservationIgnored private var startAngle: CGFloat = 0
    @ObservationIgnored private var startCenter: CGPoint = .zero
    @ObservationIgnored private var startSpread: CGFloat = 0
    @ObservationIgnored private var lastLength: CGFloat = 1
    @ObservationIgnored private var lastAngle: CGFloat = 0
    @ObservationIgnored private var lastCenter: CGPoint = .zero
    @ObservationIgnored private var rawAngle: CGFloat = 0
    @ObservationIgnored private var unwrappedAngle: CGFloat = 0
    @ObservationIgnored private var panTotal: CGPoint = .zero
    @ObservationIgnored private var panSamples: [(t: TimeInterval, p: CGPoint)] = []
    @ObservationIgnored private var fLength = OneEuroFilter(minCutoff: 2.0, beta: 4.0)
    @ObservationIgnored private var fAngle = OneEuroFilter(minCutoff: 1.5, beta: 0.5)
    @ObservationIgnored private var fx = OneEuroFilter(minCutoff: 1.5, beta: 4.0)
    @ObservationIgnored private var fy = OneEuroFilter(minCutoff: 1.5, beta: 4.0)

    @ObservationIgnored private var swipeSamples: [(t: TimeInterval, a: CGPoint, b: CGPoint, palm: CGFloat)] = []
    @ObservationIgnored private var lastSwipe: TimeInterval = -.infinity

    // MARK: Input

    /// Call once per camera frame, after the cursor has ingested the same frame. Pass a nil owner
    /// when the cursor shouldn't respond (looking away, no permission).
    func update(owner: HandFrame?, partner: HandFrame?, aspect: CGFloat, cursor: HandCursor, at t: TimeInterval) {
        self.aspect = aspect
        now = t
        guard let owner, cursor.isActive else {
            cancel(cursor: cursor)
            return
        }
        ownerPinch.update(owner.pinch, on: cursor.pinchOn, off: cursor.pinchOff, at: t)

        var other = partner
        if let partner {
            partnerPinch.update(partner.pinch, on: cursor.pinchOn, off: cursor.pinchOff, at: t)
            lastPartner = partner
            partnerLostAt = nil
        } else if let held = lastPartner {
            let since = partnerLostAt ?? t
            partnerLostAt = since
            if phase != .idle, t - since <= partnerGrace {
                other = held
            } else if t - since > partnerGrace {
                partnerPinch.reset()
                lastPartner = nil
            }
        }

        switch phase {
        case .idle:
            guard let other else {
                swipeSamples.removeAll()
                return
            }
            if quietUntilOpen {
                if !ownerPinch.on && !partnerPinch.on { quietUntilOpen = false } else { return }
            }
            if ownerPinch.on, partnerPinch.on, abs(ownerPinch.since - partnerPinch.since) <= onsetWindow,
               cursor.beginTwoHand() {
                begin(owner, other, cursor: cursor, at: t)
            } else if partnerPinch.on, !ownerPinch.on, t - partnerPinch.since >= modifierDelay, cursor.phase == .free {
                phase = .modifier
                onModifier?(true)
            } else if swipesEnabled {
                trackSwipe(owner, other, cursor: cursor, at: t)
            }

        case .manipulating:
            guard let other, ownerPinch.on, partnerPinch.on, cursor.phase == .twoHand else {
                end(cursor: cursor)
                return
            }
            step(owner, other, cursor: cursor, at: t)

        case .modifier:
            if other == nil || !partnerPinch.on {
                phase = .idle
                onModifier?(false)
            }
        }
    }

    /// Stops everything (cursor put away, feature turned off). Releases Shift if it was held.
    func cancel(cursor: HandCursor) {
        switch phase {
        case .manipulating: end(cursor: cursor)
        case .modifier:
            phase = .idle
            onModifier?(false)
        case .idle: break
        }
        ownerPinch.reset()
        partnerPinch.reset()
        lastPartner = nil
        partnerLostAt = nil
        quietUntilOpen = false
        if !swipeSamples.isEmpty { swipeSamples.removeAll() }
    }

    /// One line for the menu bar while both hands are working.
    var statusText: String {
        var parts: [String] = []
        if zooming { parts.append("Zoom \(Int((scale * 100).rounded()))%") }
        if rotating { parts.append("Rotate \(Int(rotation.rounded()))°") }
        if panning { parts.append("Pan") }
        return parts.isEmpty ? "Both hands — spread to zoom, twist to rotate, move to pan" : parts.joined(separator: " · ")
    }

    // MARK: Pinch-zoom, rotate, pan

    /// Pointer hand → other hand, with x scaled so distances and angles are true on both axes.
    private func vector(_ a: HandFrame, _ b: HandFrame) -> CGPoint {
        CGPoint(x: (b.anchor.x - a.anchor.x) * aspect, y: b.anchor.y - a.anchor.y)
    }

    private func begin(_ owner: HandFrame, _ other: HandFrame, cursor: HandCursor, at t: TimeInterval) {
        phase = .manipulating
        beganAt = t
        zooming = false
        rotating = false
        panning = false
        scale = 1
        rotation = 0
        fLength.reset()
        fAngle.reset()
        fx.reset()
        fy.reset()
        let v = vector(owner, other)
        startLength = max(hypot(v.x, v.y), 0.0001)
        rawAngle = atan2(v.y, v.x)
        unwrappedAngle = rawAngle
        startAngle = rawAngle
        startCenter = CGPoint(x: (owner.anchor.x + other.anchor.x) / 2, y: (owner.anchor.y + other.anchor.y) / 2)
        lastLength = startLength
        lastAngle = startAngle
        lastCenter = startCenter
        spread = cursor.screenVector(fromCamera: CGPoint(x: other.anchor.x - owner.anchor.x, y: other.anchor.y - owner.anchor.y))
        startSpread = hypot(spread.x, spread.y)
        panTotal = .zero
        panSamples.removeAll()
        swipeSamples.removeAll()
        _ = fLength.filter(Double(startLength), at: t)
        _ = fAngle.filter(Double(startAngle), at: t)
        _ = fx.filter(Double(startCenter.x), at: t)
        _ = fy.filter(Double(startCenter.y), at: t)
    }

    private func step(_ owner: HandFrame, _ other: HandFrame, cursor: HandCursor, at t: TimeInterval) {
        let v = vector(owner, other)
        let length = max(CGFloat(fLength.filter(Double(hypot(v.x, v.y)), at: t)), 0.0001)

        // Unwrap so a twist past ±180° doesn't flip the sign.
        let a = atan2(v.y, v.x)
        var d = a - rawAngle
        if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
        rawAngle = a
        unwrappedAngle += d
        let angle = CGFloat(fAngle.filter(Double(unwrappedAngle), at: t))

        let center = CGPoint(x: CGFloat(fx.filter(Double((owner.anchor.x + other.anchor.x) / 2), at: t)),
                             y: CGFloat(fy.filter(Double((owner.anchor.y + other.anchor.y) / 2), at: t)))
        let s = cursor.screenVector(fromCamera: CGPoint(x: other.anchor.x - owner.anchor.x, y: other.anchor.y - owner.anchor.y))
        if s.distance(to: spread) > 0.5 { spread = s }

        if !zooming, abs(log(length / startLength)) > zoomDeadband {
            zooming = true
            lastLength = length
            onZoomBegan?()
        }
        if !rotating, abs(angle - startAngle) > rotateDeadband {
            rotating = true
            lastAngle = angle
            onRotateBegan?()
        }
        if !panning {
            // Moving one hand to zoom also moves the midpoint; only pan when the hands travel together.
            let moved = cursor.screenVector(fromCamera: CGPoint(x: center.x - startCenter.x, y: center.y - startCenter.y))
            let movedBy = hypot(moved.x, moved.y)
            let spreadChange = abs(hypot(spread.x, spread.y) - startSpread)
            if movedBy > panDeadband, movedBy > spreadChange * 0.75 {
                panning = true
                lastCenter = center
                onPanBegan?()
            }
        }

        if zooming {
            let m = pow(length / lastLength, zoomGain) - 1
            lastLength = length
            if abs(m) > 0.0005 {
                scale *= 1 + m
                onZoom?(m)
            }
        }
        if rotating {
            // Screen y points down, so a growing angle is clockwise; trackpads report counterclockwise.
            let deg = -(angle - lastAngle) * 180 / .pi
            lastAngle = angle
            if abs(deg) > 0.05 {
                rotation += deg
                onRotate?(deg)
            }
        }
        if panning {
            let delta = cursor.screenVector(fromCamera: CGPoint(x: center.x - lastCenter.x, y: center.y - lastCenter.y))
            lastCenter = center
            panTotal = CGPoint(x: panTotal.x + delta.x, y: panTotal.y + delta.y)
            panSamples.append((t: t, p: panTotal))
            panSamples.removeAll { t - $0.t > 0.12 }
            if delta.x != 0 || delta.y != 0 { onPan?(delta.x, delta.y) }
        }
    }

    private func end(cursor: HandCursor) {
        guard phase == .manipulating else { return }
        if zooming { onZoomEnded?() }
        if rotating { onRotateEnded?() }
        let wasTap = !zooming && !rotating && !panning && now - beganAt < 0.4
        if panning {
            var v = CGPoint.zero
            if let first = panSamples.first, let last = panSamples.last, last.t > first.t {
                let dt = CGFloat(last.t - first.t)
                v = CGPoint(x: (last.p.x - first.p.x) / dt, y: (last.p.y - first.p.y) / dt)
            }
            onPanEnded?(v.x, v.y)
        }
        zooming = false
        rotating = false
        panning = false
        spread = .zero
        phase = .idle
        quietUntilOpen = true
        cursor.endTwoHand()
        if wasTap { onTap?() }
    }

    // MARK: Swipes

    private func trackSwipe(_ owner: HandFrame, _ other: HandFrame, cursor: HandCursor, at t: TimeInterval) {
        guard cursor.phase == .free, !ownerPinch.on, !partnerPinch.on,
              owner.pose != .fist, other.pose != .fist else {
            if !swipeSamples.isEmpty { swipeSamples.removeAll() }
            return
        }
        swipeSamples.append((t: t, a: owner.anchor, b: other.anchor, palm: (owner.palm + other.palm) / 2))
        swipeSamples.removeAll { t - $0.t > 0.3 }
        guard t - lastSwipe > swipeCooldown,
              let first = swipeSamples.first, let last = swipeSamples.last, last.t - first.t > 0.08 else { return }

        let dt = CGFloat(last.t - first.t)
        let palm = max(last.palm, 0.01)
        func travel(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            CGPoint(x: (to.x - from.x) * aspect / palm, y: (to.y - from.y) / palm)
        }
        let ma = travel(first.a, last.a)
        let mb = travel(first.b, last.b)
        let la = hypot(ma.x, ma.y)
        let lb = hypot(mb.x, mb.y)
        guard la > swipeTravel, lb > swipeTravel, la / dt > swipeSpeed, lb / dt > swipeSpeed else { return }
        let cosine = (ma.x * mb.x + ma.y * mb.y) / (la * lb)
        if cosine < -0.6 {
            // Opposite directions: pulling apart or pushing together.
            let before = hypot((first.b.x - first.a.x) * aspect, first.b.y - first.a.y) / palm
            let after = hypot((last.b.x - last.a.x) * aspect, last.b.y - last.a.y) / palm
            guard abs(after - before) > swipeTravel * 1.5 else { return }
            lastSwipe = t
            swipeSamples.removeAll()
            onSwipe?(after > before ? .apart : .together)
            return
        }
        // Both hands going the same way.
        guard cosine > 0.8 else { return }

        let m = CGPoint(x: (ma.x + mb.x) / 2, y: (ma.y + mb.y) / 2)
        let direction: TwoHandSwipe
        if abs(m.x) > abs(m.y) * 1.3 {
            direction = m.x < 0 ? .left : .right
        } else if abs(m.y) > abs(m.x) * 1.3 {
            direction = m.y < 0 ? .up : .down
        } else {
            return
        }
        lastSwipe = t
        swipeSamples.removeAll()
        onSwipe?(direction)
    }
}

/// Thumb–index pinch with hysteresis and a two-frame debounce, like `HandCursor`'s own.
private struct PinchLatch {
    private(set) var on = false
    /// When the latch last changed state.
    private(set) var since: TimeInterval = -.infinity
    private var count = 0

    mutating func update(_ value: CGFloat, on onAt: CGFloat, off offAt: CGFloat, at t: TimeInterval) {
        if !on {
            count = value < onAt ? count + 1 : 0
            if count >= 2 {
                on = true
                since = t
                count = 0
            }
        } else {
            count = value > offAt ? count + 1 : 0
            if count >= 2 {
                on = false
                since = t
                count = 0
            }
        }
    }

    mutating func reset() {
        on = false
        count = 0
        since = -.infinity
    }
}
