import AppKit
import SwiftUI

@main
struct AirControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Air Control", id: "settings") {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        if !AX.isTrusted { AX.requestTrust() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

/// The menu bar icon. Fills in while your hand drives the pointer; also opens Settings when the
/// model asks (first launch without permissions).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onChange(of: app.settingsRequest) { _, _ in
                openWindow(id: "settings")
                NSApp.activate()
            }
            .onAppear {
                if app.settingsRequest > 0 {
                    openWindow(id: "settings")
                    NSApp.activate()
                }
            }
    }

    private var symbol: String {
        if !app.accessibilityGranted { return "hand.raised.slash" }
        if app.voice.dictating { return "text.cursor" }
        if app.cursor.isActive { return "hand.raised.fill" }
        if app.voice.phase == .awake { return "waveform" }
        return "hand.raised"
    }
}
