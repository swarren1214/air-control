import CoreGraphics
import Foundation
import Observation

/// Tracking speed: how much hand movement crosses the screen, measured in palm lengths (wrist to
/// knuckle) so it feels the same whether you sit close or lean back. The setting is 0 (slow and
/// precise) … 1 (fast), mapped on a log scale so every notch of the slider feels equally big.
enum TrackingSpeed {
    /// Palm lengths of hand travel to cross the screen vertically, at each end of the slider.
    static let slowest: CGFloat = 5.6
    static let fastest: CGFloat = 1.7
    /// ≈ 3.2 palm lengths, the old "Normal".
    static let defaultValue: Double = 0.48

    static func palmsPerScreen(_ value: Double) -> CGFloat {
        let v = CGFloat(min(max(value, 0), 1))
        return slowest * pow(fastest / slowest, v)
    }

    /// Earlier builds stored one of three presets.
    static func migrate(preset: String) -> Double? {
        switch preset {
        case "precise": return 0.24
        case "normal": return defaultValue
        case "fast": return 0.74
        default: return nil
        }
    }
}

enum GestureDirection {
    case left, right, up, down
}

enum HandCursorPhase: Equatable {
    case hidden
    /// Open palm seen; the cursor appears once this reaches 1.
    case acquiring(Double)
    case free
    /// Fingers pinched; a tap if released soon without moving.
    case pressed
    /// Pinched and held still: release for a right-click, move to drag.
    case holding
    /// Pinch-hold-move: the mouse button is down and the pointer follows the hand.
    case dragging
    /// Pinch-move: content scrolls with the hand.
    case scrolling
    /// Hand briefly lost; the cursor waits in place.
    case coasting
    /// Both hands pinched: `TwoHandGestures` is zooming, rotating or panning; the pointer stays put.
    case twoHand
    /// ✌️ or three fingers up: the pointer waits while the hand swipes (pages, Spaces, Mission Control).
    case gesture(HandPose)
}

/// Turns hand frames into a Mac pointer, the way the iPadOS pointer turns a trackpad into one:
///
/// - open palm, hold → cursor appears (where the mouse pointer already is)
/// - move hand → pointer moves
/// - pinch → click (two quick pinches double-click)
/// - pinch and move → scroll, with momentum when you let go
/// - pinch and hold → ring fills; let go for a right-click, or move to drag (windows, files, text)
/// - fist → put the cursor away
///
/// Coordinates are global display points with the origin at the top-left of the main display
/// (the Quartz / Core Graphics convention used by CGEvent and the Accessibility API).
@Observable
final class HandCursor {
    // MARK: Tunables
    /// Palm lengths of hand travel to cross the screen (see `TrackingSpeed`). Set with `setPalmsPerScreen`.
    @ObservationIgnored private(set) var palmsPerScreen: CGFloat = 3.2
    var acquireDelay: TimeInterval = 0.3
    var coastDelay: TimeInterval = 0.4
    var poseHold: TimeInterval = 0.25
    /// Hold a pinch this long without moving to arm right-click / drag.
    var holdDelay: TimeInterval = 0.5
    /// Hand travel (screen points) that turns a pinch into a scroll.
    var scrollThreshold: CGFloat = 22
    /// Hand travel after the hold ring fills that starts a drag.
    var dragThreshold: CGFloat = 8
    /// Thumb-to-index gap in palm lengths that counts as a pinch (touching reads ≈ 0.1–0.15).
    var pinchOnClose: CGFloat = 0.15
    var pinchOnFar: CGFloat = 0.19
    var pinchGap: CGFloat = 0.14
    var pressFrames = 2
    var releaseFrames = 2
    /// Up close, crossing the screen takes this fraction of the usual hand travel.
    var closeRangeTravel: CGFloat = 0.5
    var closePalm: CGFloat = 0.30
    var farPalm: CGFloat = 0.10
    /// ✌️ and three-finger swipes. Off: those poses move the pointer like any other.
    var fingerGestures = true
    /// A swipe: this many palm lengths of travel, at least this fast (palm lengths per second).
    var swipeTravel: CGFloat = 1.3
    var swipeSpeed: CGFloat = 4.5

    // MARK: Observable state
    private(set) var phase: HandCursorPhase = .hidden
    /// Where the hand points, in global display points (filtered).
    private(set) var point: CGPoint = .zero
    /// Where the pinch started (the pointer stays here while pressing, holding and scrolling).
    private(set) var pinchLocation: CGPoint = .zero
    /// 0…1 while holding a pinch still, for the ring that fills before right-click / drag.
    private(set) var holdProgress: Double = 0
    /// 0 = fingers open, 1 = touching. Drives the cursor shrinking as you pinch.
    private(set) var pinchAmount: CGFloat = 0
    private(set) var pinchOn: CGFloat = 0.17
    var pinchOff: CGFloat { pinchOn + pinchGap }

    var isActive: Bool {
        switch phase {
        case .hidden, .acquiring: return false
        default: return true
        }
    }

    // MARK: Wiring
    /// The display the cursor lives on, in global points.
    @ObservationIgnored var display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// Camera frame width / height.
    @ObservationIgnored var frameAspect: CGFloat = 16.0 / 9.0
    /// Where the real pointer is right now (snapped targets included). Read when a pinch starts.
    @ObservationIgnored var pointerLocation: () -> CGPoint = { .zero }
    /// Called when the cursor first appears; return the display to use and where the pointer is.
    @ObservationIgnored var onActivate: (() -> (display: CGRect, pointer: CGPoint))?
    @ObservationIgnored var onTap: ((CGPoint) -> Void)?
    @ObservationIgnored var onRightClick: ((CGPoint) -> Void)?
    @ObservationIgnored var onDragBegan: ((CGPoint) -> Void)?
    @ObservationIgnored var onDragEnded: ((CGPoint) -> Void)?
    @ObservationIgnored var onScrollBegan: (() -> Void)?
    /// Hand movement since the last frame, in screen points (content follows the hand).
    @ObservationIgnored var onScroll: ((CGFloat, CGFloat) -> Void)?
    /// Release velocity in points per second.
    @ObservationIgnored var onScrollEnded: ((CGFloat, CGFloat) -> Void)?
    @ObservationIgnored var onPose: ((HandPose) -> Void)?
    /// A ✌️ or three-finger swipe.
    @ObservationIgnored var onSwipe: ((HandPose, GestureDirection) -> Void)?
    @ObservationIgnored var onDeactivate: (() -> Void)?

    // MARK: Private
    @ObservationIgnored private var fx = OneEuroFilter(minCutoff: 1.0, beta: 0.012)
    @ObservationIgnored private var fy = OneEuroFilter(minCutoff: 1.0, beta: 0.012)
    /// The window of the camera frame mapped onto the display. Pushing past an edge slides it
    /// along (ratchet), so every edge stays reachable.
    @ObservationIgnored private var region = CGRect(x: 0.34, y: 0.34, width: 0.32, height: 0.32)
    @ObservationIgnored private var regionHeight: CGFloat = 0.32
    @ObservationIgnored private var palmEstimate: CGFloat = 0
    @ObservationIgnored private var palmSince: TimeInterval?
    @ObservationIgnored private var lostSince: TimeInterval?
    @ObservationIgnored private var pinching = false
    @ObservationIgnored private var closedFrames = 0
    @ObservationIgnored private var openFrames = 0
    @ObservationIgnored private var pinchStart: TimeInterval = 0
    @ObservationIgnored private var pinchStartHand: CGPoint = .zero
    @ObservationIgnored private var lastHand: CGPoint = .zero
    /// The hand's latest raw camera position, for re-anchoring after a scroll.
    @ObservationIgnored private var lastAnchor: CGPoint = .zero
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var samples: [(t: TimeInterval, p: CGPoint)] = []
    @ObservationIgnored private var stablePose: HandPose = .none
    @ObservationIgnored private var poseSince: TimeInterval = 0
    @ObservationIgnored private var firedPose: HandPose = .none
    /// After a two-hand gesture, ignore the pinch that drove it until the fingers open.
    @ObservationIgnored private var needsOpen = false
    @ObservationIgnored private var gestureFrames = 0
    @ObservationIgnored private var gestureSince: TimeInterval = 0
    @ObservationIgnored private var gestureSeen: TimeInterval = 0
    @ObservationIgnored private var gestureOrigin: CGPoint = .zero
    @ObservationIgnored private var gestureSamples: [(t: TimeInterval, p: CGPoint)] = []
    @ObservationIgnored private var lastSwipeAt: TimeInterval = -.infinity
    @ObservationIgnored private var talkFired = false
    /// The hand was lost mid-gesture: when it's back, pick up where the pointer waited.
    @ObservationIgnored private var reanchorOnReturn = false

    // MARK: Input

    /// Pass nil when no hand is visible — or when the person isn't looking at the screen.
    func ingest(_ frame: HandFrame?, at t: TimeInterval) {
        guard let frame else {
            handLost(at: t)
            return
        }
        lostSince = nil
        palmEstimate = palmEstimate == 0 ? frame.palm : palmEstimate + (frame.palm - palmEstimate) * 0.15

        if !isActive {
            acquire(frame, at: t)
            return
        }

        if phase == .coasting {
            setPhase(.free)
            if reanchorOnReturn {
                reanchorOnReturn = false
                anchorRegion(hand: frame.anchor, at: point, palm: palmEstimate)
                fx.reset()
                fy.reset()
            }
        }
        if phase == .twoHand {
            // Both hands are working the content; the pointer waits where the pinch started.
            lastAnchor = frame.anchor
            return
        }
        if !pinching {
            adaptRegion(palm: palmEstimate)
            let on = pinchOnFar + (pinchOnClose - pinchOnFar) * closeness(palm: palmEstimate)
            if abs(on - pinchOn) > 0.005 { pinchOn = on }
            trackPose(frame.pose, at: t)
            guard isActive else { return }   // a fist puts the cursor away
            if fingerGestures, handleGesture(frame, at: t) {
                lastAnchor = frame.anchor
                return
            }
        }
        lastAnchor = frame.anchor
        let mapped = map(frame.anchor, at: t)
        if mapped != point { point = mapped }
        let amount = min(max((pinchOff - frame.pinch) / max(pinchOff - pinchOn * 0.6, 0.01), 0), 1)
        if abs(amount - pinchAmount) > 0.03 { pinchAmount = amount }
        updatePinch(frame.pinch, at: t)
    }

    /// Puts the cursor away (fist, the physical mouse moved, tracking turned off…).
    func reset() {
        let wasActive = isActive
        endInteraction()
        setPhase(.hidden)
        palmSince = nil
        palmEstimate = 0
        closedFrames = 0
        openFrames = 0
        holdProgress = 0
        pinchAmount = 0
        stablePose = .none
        firedPose = .none
        needsOpen = false
        gestureFrames = 0
        gestureSamples.removeAll()
        reanchorOnReturn = false
        fx.reset()
        fy.reset()
        if wasActive { onDeactivate?() }
    }

    private func acquire(_ frame: HandFrame, at t: TimeInterval) {
        guard frame.pose == .openPalm else {
            palmSince = nil
            if phase != .hidden { setPhase(.hidden) }
            return
        }
        if palmSince == nil {
            // Start where the mouse pointer already is, so nothing jumps.
            let start = onActivate?() ?? (display: display, pointer: CGPoint(x: display.midX, y: display.midY))
            display = start.display
            anchorRegion(hand: frame.anchor, at: start.pointer, palm: palmEstimate)
            fx.reset()
            fy.reset()
            point = start.pointer
        }
        let since = palmSince ?? t
        palmSince = since
        let progress = min(1, (t - since) / acquireDelay)
        if progress >= 1 {
            point = map(frame.anchor, at: t)
            firedPose = .openPalm
            setPhase(.free)
        } else {
            setPhase(.acquiring(progress))
        }
    }

    private func handLost(at t: TimeInterval) {
        palmSince = nil
        stablePose = .none
        guard isActive else {
            if phase != .hidden { setPhase(.hidden) }
            return
        }
        // Coast briefly so a hand passing out of frame for a moment doesn't drop the cursor.
        if lostSince == nil {
            lostSince = t
            if case .gesture = phase {
                gestureSamples.removeAll()
                reanchorOnReturn = true
            }
            endTwoHand()
            endInteraction()
            setPhase(.coasting)
        }
        if let since = lostSince, t - since > coastDelay { reset() }
    }

    /// Ends whatever the pinch was doing without firing a click.
    private func endInteraction() {
        if pinching {
            switch phase {
            case .dragging: onDragEnded?(point)
            case .scrolling: onScrollEnded?(0, 0)
            default: break
            }
        }
        pinching = false
        armed = false
        holdProgress = 0
        samples.removeAll()
    }

    // MARK: Poses

    private func trackPose(_ pose: HandPose, at t: TimeInterval) {
        if pose != stablePose {
            stablePose = pose
            poseSince = t
            if pose != firedPose { firedPose = .none }
            return
        }
        guard t - poseSince >= poseHold, firedPose != pose else { return }
        switch pose {
        case .fist:
            firedPose = pose
            onPose?(.fist)
            reset()
        case .thumbsUp:
            firedPose = pose
            onPose?(pose)
        case .victory where !fingerGestures:
            // With finger gestures on, ✌️ talks only when held still (see `handleGesture`).
            firedPose = pose
            onPose?(pose)
        default:
            break
        }
    }

    // MARK: Finger gestures

    /// ✌️ or three fingers: hold the pose and the pointer waits; swipe to fire. Like two- and
    /// three-finger swipes on a trackpad. Returns true while the hand is in gesture mode (the
    /// pointer and pinch are left alone).
    private func handleGesture(_ frame: HandFrame, at t: TimeInterval) -> Bool {
        let pose = frame.pose
        let isGesturePose = pose == .victory || pose == .threeFingers
        guard case .gesture(let mode) = phase else {
            guard phase == .free else {
                gestureFrames = 0
                return false
            }
            gestureFrames = isGesturePose ? gestureFrames + 1 : 0
            guard gestureFrames >= 3 else { return false }
            gestureFrames = 0
            gestureSince = t
            gestureSeen = t
            gestureOrigin = frame.anchor
            gestureSamples = [(t: t, p: frame.anchor)]
            talkFired = false
            setPhase(.gesture(pose))
            return true
        }

        if isGesturePose {
            gestureSeen = t
            // Fingers settle in the first moment: let ✌️ become three fingers or back.
            if pose != mode, t - gestureSince < 0.35 { setPhase(.gesture(pose)) }
        } else if pose == .openPalm || pose == .fist || pose == .pointing || t - gestureSeen > 0.25 {
            // Motion blur mid-swipe often reads as "other"; only a clear new pose ends the gesture.
            exitGesture(frame)
            return false
        }

        let current: HandPose
        if case .gesture(let m) = phase { current = m } else { current = mode }
        let palm = max(palmEstimate, 0.01)

        gestureSamples.append((t: t, p: frame.anchor))
        gestureSamples.removeAll { t - $0.t > 0.3 }
        if t - lastSwipeAt > 0.7, let first = gestureSamples.first, let last = gestureSamples.last, last.t - first.t > 0.06 {
            let dx = (last.p.x - first.p.x) * frameAspect / palm
            let dy = (last.p.y - first.p.y) / palm
            let distance = hypot(dx, dy)
            if distance > swipeTravel, distance / CGFloat(last.t - first.t) > swipeSpeed {
                var direction: GestureDirection?
                if abs(dx) > abs(dy) * 1.3 {
                    direction = dx < 0 ? .left : .right
                } else if abs(dy) > abs(dx) * 1.3 {
                    direction = dy < 0 ? .up : .down
                }
                if let direction {
                    lastSwipeAt = t
                    gestureSamples.removeAll()
                    talkFired = true   // a swipe isn't a request to talk
                    onSwipe?(current, direction)
                }
            }
        }

        // ✌️ held still: talk without "Hey Mac".
        if current == .victory, !talkFired, t - gestureSince >= 0.45 {
            let drift = hypot((frame.anchor.x - gestureOrigin.x) * frameAspect, frame.anchor.y - gestureOrigin.y) / palm
            if drift < 0.6 {
                talkFired = true
                onPose?(.victory)
            }
        }
        return true
    }

    private func exitGesture(_ frame: HandFrame) {
        // Pick up where the pointer waited, so it doesn't jump to wherever the hand ended up.
        anchorRegion(hand: frame.anchor, at: point, palm: palmEstimate)
        fx.reset()
        fy.reset()
        gestureSamples.removeAll()
        setPhase(.free)
    }

    // MARK: Pinch

    private func updatePinch(_ value: CGFloat, at t: TimeInterval) {
        if !pinching {
            if needsOpen {
                if value > pinchOff { needsOpen = false }
                closedFrames = 0
                return
            }
            closedFrames = value < pinchOn ? closedFrames + 1 : 0
            guard closedFrames >= pressFrames else { return }
            closedFrames = 0
            openFrames = 0
            pinching = true
            armed = false
            pinchStart = t
            pinchStartHand = point
            lastHand = point
            pinchLocation = pointerLocation()
            holdProgress = 0
            samples = [(t: t, p: point)]
            setPhase(.pressed)
            return
        }

        samples.append((t: t, p: point))
        samples.removeAll { t - $0.t > 0.12 }
        let moved = point.distance(to: pinchStartHand)

        switch phase {
        case .pressed:
            if moved > scrollThreshold {
                lastHand = point
                setPhase(.scrolling)
                onScrollBegan?()
            } else {
                let p = min(1, (t - pinchStart) / holdDelay)
                if abs(p - holdProgress) > 0.02 || p == 1 { holdProgress = p }
                if p >= 1 {
                    armed = true
                    pinchStartHand = point
                    setPhase(.holding)
                }
            }
        case .holding:
            if moved > dragThreshold {
                setPhase(.dragging)
                onDragBegan?(pinchLocation)
            }
        case .scrolling:
            let d = CGPoint(x: point.x - lastHand.x, y: point.y - lastHand.y)
            lastHand = point
            if d.x != 0 || d.y != 0 { onScroll?(d.x, d.y) }
        default:
            break
        }

        openFrames = value > pinchOff ? openFrames + 1 : 0
        guard openFrames >= releaseFrames else { return }

        pinching = false
        holdProgress = 0
        switch phase {
        case .pressed:
            onTap?(pinchLocation)
        case .holding:
            onRightClick?(pinchLocation)
        case .dragging:
            onDragEnded?(point)
        case .scrolling:
            let v = releaseVelocity()
            onScrollEnded?(v.x, v.y)
            // The pointer stayed put while the hand moved to scroll; re-map so the hand's new
            // position lands where the pointer is, instead of the pointer flying after it.
            anchorRegion(hand: lastAnchor, at: pinchLocation, palm: palmEstimate)
            fx.reset()
            fy.reset()
            point = pinchLocation
        default:
            break
        }
        armed = false
        setPhase(.free)
    }

    private func releaseVelocity() -> CGPoint {
        guard let first = samples.first, let last = samples.last, last.t > first.t else { return .zero }
        let dt = CGFloat(last.t - first.t)
        return CGPoint(x: (last.p.x - first.p.x) / dt, y: (last.p.y - first.p.y) / dt)
    }

    // MARK: Speed and two hands

    /// Changes tracking speed immediately, keeping the pointer exactly where it is.
    func setPalmsPerScreen(_ palms: CGFloat) {
        guard abs(palms - palmsPerScreen) > 0.001 else { return }
        palmsPerScreen = palms
        if isActive, !pinching, phase != .twoHand, palmEstimate > 0 {
            anchorRegion(hand: lastAnchor, at: point, palm: palmEstimate)
        }
    }

    /// Hands the pointer hand's pinch over to a two-hand gesture. Only allowed before the pinch has
    /// done anything (a tap fires on release, a scroll only after moving), so nothing needs undoing.
    @discardableResult
    func beginTwoHand() -> Bool {
        switch phase {
        case .free:
            pinchLocation = pointerLocation()
        case .pressed:
            break   // keep the spot where the pinch started
        default:
            return false
        }
        pinching = false
        armed = false
        closedFrames = 0
        openFrames = 0
        holdProgress = 0
        samples.removeAll()
        setPhase(.twoHand)
        return true
    }

    /// Back to one hand. The pointer stays where the gesture happened instead of jumping to the hand.
    func endTwoHand() {
        guard phase == .twoHand else { return }
        anchorRegion(hand: lastAnchor, at: pinchLocation, palm: palmEstimate)
        fx.reset()
        fy.reset()
        point = pinchLocation
        needsOpen = true
        setPhase(.free)
    }

    /// A hand movement in camera units, as screen points at the current tracking speed.
    func screenVector(fromCamera d: CGPoint) -> CGPoint {
        guard region.width > 0, region.height > 0 else { return .zero }
        return CGPoint(x: d.x / region.width * display.width, y: d.y / region.height * display.height)
    }

    // MARK: Mapping

    /// 0 when far from the camera, 1 when close (log scale: apparent size halves as distance doubles).
    private func closeness(palm: CGFloat) -> CGFloat {
        guard palm > 0, closePalm > farPalm else { return 0 }
        let v = (log(palm) - log(farPalm)) / (log(closePalm) - log(farPalm))
        let c = min(max(v, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Height of the camera region mapped onto the display. Measured in palm lengths so the same
    /// physical motion works at any distance; up close it shrinks further so small moves go far.
    private func targetHeight(palm: CGFloat) -> CGFloat {
        let travel = 1 - (1 - closeRangeTravel) * closeness(palm: palm)
        return min(max(palm * palmsPerScreen * travel, 0.05), 0.8)
    }

    /// Width in camera units that keeps the same physical gain on both axes.
    private func width(forHeight h: CGFloat) -> CGFloat {
        let aspect = display.height > 0 ? display.width / display.height : 16.0 / 10.0
        return h * aspect / max(frameAspect, 0.1)
    }

    /// Places the region so the hand maps exactly onto the given pointer location.
    private func anchorRegion(hand: CGPoint, at pointer: CGPoint, palm: CGFloat) {
        let h = targetHeight(palm: palm)
        let w = width(forHeight: h)
        regionHeight = h
        let nx = display.width > 0 ? (pointer.x - display.minX) / display.width : 0.5
        let ny = display.height > 0 ? (pointer.y - display.minY) / display.height : 0.5
        region = CGRect(x: hand.x - nx * w, y: hand.y - ny * h, width: w, height: h)
    }

    /// Follows you leaning in or back, slowly, so the gain never jumps mid-move.
    private func adaptRegion(palm: CGFloat) {
        let target = targetHeight(palm: palm)
        guard abs(target - regionHeight) / regionHeight > 0.15 else { return }
        let h = regionHeight + (target - regionHeight) * 0.02
        let w = width(forHeight: h)
        let c = CGPoint(x: region.midX, y: region.midY)
        regionHeight = h
        region = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    private func map(_ p: CGPoint, at t: TimeInterval) -> CGPoint {
        if p.x < region.minX { region.origin.x = p.x } else if p.x > region.maxX { region.origin.x = p.x - region.width }
        if p.y < region.minY { region.origin.y = p.y } else if p.y > region.maxY { region.origin.y = p.y - region.height }
        let nx = min(max((p.x - region.minX) / region.width, 0), 1)
        let ny = min(max((p.y - region.minY) / region.height, 0), 1)
        let x = fx.filter(Double(display.minX + nx * (display.width - 1)), at: t)
        let y = fy.filter(Double(display.minY + ny * (display.height - 1)), at: t)
        return CGPoint(x: x, y: y)
    }

    private func setPhase(_ p: HandCursorPhase) {
        if phase != p { phase = p }
    }
}
