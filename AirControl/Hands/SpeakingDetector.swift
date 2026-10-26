import CoreGraphics
import Foundation

/// Watches the lips of whoever is looking at the screen and keeps a short history of whether
/// they were talking. Voice commands are then checked against that history, so cross talk from
/// other people — whose mouths aren't the one moving — is ignored.
///
/// This tells *who* is speaking, not *what* they said; the words still come from speech recognition.
struct SpeakingDetector {
    enum MouthState {
        case speaking      // a facing face whose lips are moving
        case still         // a facing face, lips not moving
        case unreliable    // someone facing the screen, but too far to read lips
        case noFace        // nobody facing the screen
    }

    enum Verdict {
        case speaking, notSpeaking, unknown, noFace
    }

    /// How much the lip gap must vary (as a fraction of face height) to count as talking.
    var rangeThreshold: CGFloat = 0.035
    var window: TimeInterval = 0.4

    private(set) var isSpeaking = false
    private var samples: [(t: TimeInterval, open: CGFloat)] = []
    private var log: [(t: TimeInterval, state: MouthState)] = []

    mutating func update(face: FaceInfo?, at t: TimeInterval) {
        let state: MouthState
        if let face, face.isFacingScreen {
            if face.mouthReliable, let open = face.mouthOpen {
                samples.append((t: t, open: open))
                samples.removeAll { t - $0.t > window }
                let values = samples.map(\.open)
                let range = (values.max() ?? 0) - (values.min() ?? 0)
                isSpeaking = samples.count >= 4 && range > rangeThreshold
                state = isSpeaking ? .speaking : .still
            } else {
                samples.removeAll()
                isSpeaking = false
                state = .unreliable
            }
        } else {
            samples.removeAll()
            isSpeaking = false
            state = .noFace
        }
        log.append((t: t, state: state))
        log.removeAll { t - $0.t > 10 }
    }

    /// Was the person looking at the screen talking between `from` and `to`?
    func verdict(from: TimeInterval, to: TimeInterval) -> Verdict {
        let span = log.filter { $0.t >= from && $0.t <= to }
        guard !span.isEmpty else { return .unknown }
        let seen = span.filter { $0.state != .noFace }
        if seen.count < span.count / 4 { return .noFace }
        let readable = seen.filter { $0.state == .speaking || $0.state == .still }
        // Mostly too far away to read lips: don't block, the looking check still applies.
        if readable.count < max(3, seen.count / 3) { return .unknown }
        let talking = readable.filter { $0.state == .speaking }.count
        return Double(talking) / Double(readable.count) >= 0.2 ? .speaking : .notSpeaking
    }
}
