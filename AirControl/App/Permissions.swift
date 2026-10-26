import AppKit
import AVFoundation
import Speech

enum Permission: CaseIterable {
    case accessibility, camera, microphone, speech

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        }
    }

    var why: String {
        switch self {
        case .accessibility: return "Move the pointer, click, scroll, type, and find buttons to snap to."
        case .camera: return "See your hand and whether you’re looking at the screen."
        case .microphone: return "Hear “Hey Mac” and voice commands."
        case .speech: return "Turn speech into text, on this Mac."
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .camera: return "Privacy_Camera"
        case .microphone: return "Privacy_Microphone"
        case .speech: return "Privacy_SpeechRecognition"
        }
    }
}

enum Permissions {
    enum State { case granted, denied, notAsked }

    static func state(_ p: Permission) -> State {
        switch p {
        case .accessibility:
            return AX.isTrusted ? .granted : .denied
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
    }

    private static func map(_ s: AVAuthorizationStatus) -> State {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Asks in-app when the system allows it; otherwise opens the right System Settings pane.
    static func request(_ p: Permission) {
        switch (p, state(p)) {
        case (.accessibility, _):
            AX.requestTrust()
            open(.accessibility)
        case (.camera, .notAsked):
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        case (.microphone, .notAsked):
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case (.speech, .notAsked):
            SFSpeechRecognizer.requestAuthorization { _ in }
        default:
            open(p)
        }
    }

    static func open(_ p: Permission) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(p.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
