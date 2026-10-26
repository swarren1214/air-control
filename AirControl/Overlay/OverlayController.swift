import AppKit
import SwiftUI

/// A click-through panel over each display. It never takes focus or mouse events; it only draws
/// the hand cursor, snap highlights, captions and toasts above everything else.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    private var panels: [NSPanel] = []
    private weak var model: AppModel?
    private var observer: NSObjectProtocol?

    func start(model: AppModel) {
        self.model = model
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        guard let model else { return }
        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            // Above menus, the Dock and full-screen apps, so the cursor is visible everywhere.
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSHostingView(rootView: OverlayView(display: Displays.globalFrame(of: screen))
                .environment(model))
            view.frame = CGRect(origin: .zero, size: screen.frame.size)
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}
