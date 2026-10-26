import CoreGraphics
import Foundation
import Observation

/// The six window controls, clockwise from the top of the ring.
enum WindowAction: Int, CaseIterable, Identifiable {
    case fullScreen, tileRight, fill, minimize, close, tileLeft

    var id: Int { rawValue }

    /// Degrees in screen space (y down): 0 is right, -90 is up.
    var angle: CGFloat { CGFloat(rawValue) * 60 - 90 }

    var title: String {
        switch self {
        case .fullScreen: return "Full Screen"
        case .tileRight: return "Tile Right"
        case .fill: return "Fill Screen"
        case .minimize: return "Minimize"
        case .close: return "Close Window"
        case .tileLeft: return "Tile Left"
        }
    }

    var symbol: String {
        switch self {
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .tileRight: return "rectangle.righthalf.filled"
        case .fill: return "rectangle.inset.filled"
        case .minimize: return "minus"
        case .close: return "xmark"
        case .tileLeft: return "rectangle.lefthalf.filled"
        }
    }

    var systemAction: SystemAction {
        switch self {
        case .fullScreen: return .fullScreenWindow
        case .tileRight: return .tileRight
        case .fill: return .fillWindow
        case .minimize: return .minimizeWindow
        case .close: return .closeWindow
        case .tileLeft: return .tileLeft
        }
    }
}

/// Point with one finger (☝️) and hold still: a ring of window controls opens around the pointer
/// for the window under it. Move toward one and pinch to do it. Pinch in the middle, make a fist,
/// or wait a few seconds to dismiss. A marking menu: once learned, it's a flick and a pinch.
@Observable
final class WindowMenu {
    static let radius: CGFloat = 96
    /// Inside this distance from the center nothing is selected.
    static let deadZone: CGFloat = 36

    var holdDelay: TimeInterval = 0.5
    /// The pointer must stay within this many points while the finger is held up.
    var stillness: CGFloat = 14
    var timeout: TimeInterval = 5

    private(set) var isOpen = false
    /// Global, top-left origin.
    private(set) var center: CGPoint = .zero
    private(set) var selection: WindowAction?
    /// The window the menu will act on, outlined while it's open.
    private(set) var windowFrame: CGRect?

    @ObservationIgnored private var pointingSince: TimeInterval?
    @ObservationIgnored private var pointingOrigin: CGPoint = .zero
    @ObservationIgnored private var lastActivity: TimeInterval = 0

    /// Call every camera frame with the pointer hand's pose. Returns true when the menu opens.
    func watch(pose: HandPose?, pointer: CGPoint, canOpen: Bool, at t: TimeInterval) -> Bool {
        guard !isOpen else { return false }
        guard canOpen, pose == .pointing else {
            pointingSince = nil
            return false
        }
        guard let since = pointingSince, pointer.distance(to: pointingOrigin) <= stillness else {
            pointingSince = t
            pointingOrigin = pointer
            return false
        }
        guard t - since >= holdDelay else { return false }
        center = pointingOrigin
        selection = nil
        windowFrame = nil
        lastActivity = t
        pointingSince = nil
        isOpen = true
        return true
    }

    /// Call every display frame while open: picks the control in the direction of the pointer.
    func track(pointer: CGPoint, at t: TimeInterval) {
        guard isOpen else { return }
        let v = CGPoint(x: pointer.x - center.x, y: pointer.y - center.y)
        var pick: WindowAction?
        if hypot(v.x, v.y) > Self.deadZone {
            var degrees = atan2(v.y, v.x) * 180 / .pi + 90   // 0 = up, clockwise
            if degrees < 0 { degrees += 360 }
            pick = WindowAction(rawValue: Int((degrees / 60).rounded()) % 6)
        }
        if pick != selection {
            selection = pick
            lastActivity = t
        }
        if t - lastActivity > timeout { close() }
    }

    func setWindowFrame(_ r: CGRect?) {
        if isOpen { windowFrame = r }
    }

    func close() {
        guard isOpen || pointingSince != nil else { return }
        isOpen = false
        selection = nil
        windowFrame = nil
        pointingSince = nil
    }
}
