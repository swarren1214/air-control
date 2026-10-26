import SwiftUI

/// The menu bar panel: status, the two main switches, and a gesture cheat sheet.
struct MenuView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: app.cursor.isActive ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(app.cursor.isActive ? Color.accentColor : Color.gray.opacity(0.5)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Air Control").font(.headline)
                    Text(app.statusLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if !app.accessibilityGranted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Allow Accessibility so Air Control can move the pointer, click and type.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Open Accessibility Settings") { Permissions.open(.accessibility) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { app.cameraEnabled }, set: { app.setCameraEnabled($0) })) {
                    Label("Hand control", systemImage: "hand.point.up.left")
                }
                .padding(.vertical, 6)
                Divider()
                Toggle(isOn: Binding(get: { app.voiceEnabled }, set: { app.setVoiceEnabled($0) })) {
                    Label("Voice — “Hey Mac”", systemImage: "mic")
                }
                .padding(.vertical, 6)
                Divider()
                Picker(selection: Binding(get: { app.previewMode }, set: { app.setPreviewMode($0) })) {
                    ForEach(PreviewMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Camera preview", systemImage: "video")
                }
                .padding(.vertical, 6)
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                GestureRow(symbol: "hand.raised", text: "Raise an open palm to take the pointer")
                GestureRow(symbol: "hand.pinch", text: "Pinch to click · twice to double-click")
                GestureRow(symbol: "arrow.up.and.down", text: "Pinch and move to scroll")
                GestureRow(symbol: "circle.dashed", text: "Pinch and hold: let go to right-click, or move to drag")
                GestureRow(symbol: "hand.raised.fingers.spread", text: "✌️ to talk without “Hey Mac”, ✊ to stop")
                if app.twoHanded {
                    GestureRow(symbol: "arrow.up.left.and.arrow.down.right", text: "Pinch both hands: spread to zoom, twist to rotate, move to pan")
                    GestureRow(symbol: "shift", text: "Hold a pinch with your other hand for Shift")
                    GestureRow(symbol: "rectangle.split.3x1", text: "Swipe both hands to change Space")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit Air Control") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct GestureRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            Text(text)
        }
    }
}
