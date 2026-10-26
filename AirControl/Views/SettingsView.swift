import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            PermissionsSection()

            Section("Hand control") {
                Toggle("Control the pointer with your hand",
                       isOn: Binding(get: { app.cameraEnabled }, set: { app.setCameraEnabled($0) }))
                Picker("Camera", selection: Binding(get: { app.cameraID ?? "" }, set: { app.setCamera($0.isEmpty ? nil : $0) })) {
                    Text("Automatic").tag("")
                    ForEach(CameraService.availableCameras(), id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                Slider(value: Binding(get: { app.trackingSpeed }, set: { app.setTrackingSpeed($0) }), in: 0...1) {
                    Text("Tracking speed")
                    Text("How far the pointer moves for each bit of hand movement. Changes apply as you drag.")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
                Toggle(isOn: Binding(get: { app.requireLooking }, set: { app.setRequireLooking($0) })) {
                    Text("Only while you’re looking at the screen")
                    Text("Glance away and the pointer goes back to your mouse.")
                }
                Toggle(isOn: Binding(get: { app.snapping }, set: { app.setSnapping($0) })) {
                    Text("Snap to buttons and links")
                    Text("The pointer settles onto controls, like the iPad pointer.")
                }
                Toggle(isOn: Binding(get: { app.hideSystemPointer }, set: { app.setHideSystemPointer($0) })) {
                    Text("Glass pointer while your hand is up")
                    Text(SystemCursor.canHide ? "Hides the arrow so the pointer can morph into controls."
                                              : "Not available on this version of macOS; the arrow stays visible.")
                }
                .disabled(!SystemCursor.canHide)
                Toggle("Reverse scroll direction",
                       isOn: Binding(get: { app.reverseScroll }, set: { app.setReverseScroll($0) }))
                Picker("Camera preview", selection: Binding(get: { app.previewMode }, set: { app.setPreviewMode($0) })) {
                    ForEach(PreviewMode.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { app.twoHanded }, set: { app.setTwoHanded($0) })) {
                    Text("Two-hand gestures")
                    Text("Pinch with both hands at once, then spread to zoom, twist to rotate, or move them together to pan.")
                }
                Picker(selection: Binding(get: { app.zoomMode }, set: { app.setZoomMode($0) })) {
                    ForEach(TwoHandZoomMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Zoom with")
                    Text(zoomModeDetail)
                }
                .disabled(!app.twoHanded)
                Toggle(isOn: Binding(get: { app.twoHandSwipes }, set: { app.setTwoHandSwipes($0) })) {
                    Text("Two-hand swipes")
                    Text("Swipe both hands left or right to change Space, up for Mission Control, down for app windows.")
                }
                .disabled(!app.twoHanded)
            } header: {
                Text("Two hands")
            } footer: {
                Text("Hold a pinch with your other hand to hold Shift: pinch-click with your pointer hand to select several things, or drag to keep proportions.")
            }

            Section("Voice") {
                Toggle(isOn: Binding(get: { app.voiceEnabled }, set: { app.setVoiceEnabled($0) })) {
                    Text("Voice commands")
                    Text("Say “Hey Mac” first — or just talk while your hand is up, or after ✌️.")
                }
                Toggle(isOn: Binding(get: { app.matchSpeaker }, set: { app.setMatchSpeaker($0) })) {
                    Text("Only listen to the person at the screen")
                    Text("Uses lip movement to ignore other people talking nearby.")
                }
                Toggle(isOn: Binding(get: { app.noiseReduction }, set: { app.setNoiseReduction($0) })) {
                    Text("Noise reduction")
                    Text("Turn off if words get clipped.")
                }
                Toggle("Live captions", isOn: Binding(get: { app.showCaptions }, set: { app.setShowCaptions($0) }))
                VoiceStatusRow()
            }

            Section("What you can say") {
                CommandRow(say: "click · double click · right click", does: "At the pointer")
                CommandRow(say: "click Send · press Save", does: "A button in the front window, by name")
                CommandRow(say: "scroll down · scroll up a lot · go to the top", does: "Where the pointer is")
                CommandRow(say: "open Safari · switch to Mail · quit Music", does: "Apps")
                CommandRow(say: "new tab · close window · go back · reload", does: "Shortcuts")
                CommandRow(say: "copy · paste · undo · select all · save", does: "Editing")
                CommandRow(say: "type see you at 5 · press command shift T", does: "Keyboard")
                CommandRow(say: "start dictation … stop dictation", does: "Type everything you say")
                CommandRow(say: "search for flights to Denver", does: "Spotlight")
                CommandRow(say: "mission control · show desktop · next space", does: "Windows and spaces")
                Text("Anything else goes to Apple’s on-device model, which can see the buttons on screen — “hit the blue continue button”, “get me back to my email”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 640)
    }

    private var zoomModeDetail: String {
        switch app.zoomMode {
        case .trackpad: return "Zooms and rotates exactly like a trackpad pinch. Try ⌘ + scroll if an app ignores it."
        case .commandScroll: return "Works in most design tools, whiteboards and canvas web apps. No rotation."
        case .keyboard: return "⌘+ and ⌘−, in steps. Works almost everywhere. No rotation."
        }
    }
}

private struct PermissionsSection: View {
    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 10) {
                    ForEach(Permission.allCases, id: \.self) { p in
                        PermissionRow(permission: p, state: Permissions.state(p))
                    }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Video and audio are processed on this Mac and never uploaded.")
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let state: Permissions.State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(state == .granted ? Color.green : Color.orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button(state == .notAsked ? "Allow" : "Open Settings") { Permissions.request(permission) }
            }
        }
    }
}

private struct VoiceStatusRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        LabeledContent {
            Text(phase).foregroundStyle(.secondary)
        } label: {
            Text("Status")
            Text(app.voice.lastHeard.isEmpty ? "Nothing heard yet" : "Last heard: “\(app.voice.lastHeard)”")
            Text(app.interpreter.isAvailable ? "Apple Intelligence: on — natural phrasing works"
                                             : "Apple Intelligence: off — only the commands below work")
        }
    }

    private var phase: String {
        switch app.voice.phase {
        case .off: return "Off"
        case .unavailable(let why): return why
        case .idle: return app.voice.openMic ? "Listening" : "Waiting for “Hey Mac”"
        case .awake: return "Hearing you"
        case .processing: return "Working…"
        }
    }
}

private struct CommandRow: View {
    let say: String
    let does: String

    var body: some View {
        LabeledContent {
            Text(does).foregroundStyle(.secondary)
        } label: {
            Text(say)
        }
    }
}
