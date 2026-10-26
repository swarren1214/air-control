import AppKit
import CoreGraphics

/// Converts between AppKit screen frames (bottom-left origin) and the global top-left space
/// that CGEvent and the Accessibility API use.
enum Displays {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func globalFrame(of screen: NSScreen) -> CGRect {
        CGDisplayBounds(displayID(of: screen))
    }

    /// The display containing a global point (falls back to the main display).
    static func display(containing p: CGPoint) -> CGRect {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 {
            return CGDisplayBounds(id)
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    /// The mouse pointer's current location, global top-left.
    static var mouseLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
