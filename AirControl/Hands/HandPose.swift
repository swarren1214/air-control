import CoreGraphics
import CoreVideo
import Vision

/// The 21 hand landmarks Vision reports, decoupled from Vision so views don't import it.
enum HandJoint: CaseIterable, Hashable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    var visionName: VNHumanHandPoseObservation.JointName {
        switch self {
        case .wrist: return .wrist
        case .thumbCMC: return .thumbCMC
        case .thumbMP: return .thumbMP
        case .thumbIP: return .thumbIP
        case .thumbTip: return .thumbTip
        case .indexMCP: return .indexMCP
        case .indexPIP: return .indexPIP
        case .indexDIP: return .indexDIP
        case .indexTip: return .indexTip
        case .middleMCP: return .middleMCP
        case .middlePIP: return .middlePIP
        case .middleDIP: return .middleDIP
        case .middleTip: return .middleTip
        case .ringMCP: return .ringMCP
        case .ringPIP: return .ringPIP
        case .ringDIP: return .ringDIP
        case .ringTip: return .ringTip
        case .littleMCP: return .littleMCP
        case .littlePIP: return .littlePIP
        case .littleDIP: return .littleDIP
        case .littleTip: return .littleTip
        }
    }

    static let bones: [(HandJoint, HandJoint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP)
    ]
}

enum HandPose: String {
    case none, openPalm, fist, thumbsUp, victory, pointing, other
}

/// Left or right hand, as Vision judges it. Only compared between two hands in the same frame,
/// so it doesn't matter whether the camera image is mirrored.
enum HandChirality {
    case unknown, left, right
}

/// One analyzed camera frame. Points are normalized 0...1, origin top-left,
/// mirrored like a selfie view (so moving your hand right moves the cursor right).
struct HandFrame {
    var joints: [HandJoint: CGPoint]
    var confidence: Float
    /// Knuckle of the middle finger. Stable while pinching, unlike a fingertip.
    var anchor: CGPoint
    var wrist: CGPoint
    /// Thumb-tip to index-tip distance divided by palm length.
    var pinch: CGFloat
    /// Wrist-to-knuckle length in units of frame height; a stand-in for how far away the hand is.
    var palm: CGFloat
    var pose: HandPose
    var chirality: HandChirality = .unknown
}

/// Head pose of the nearest face, used to tell whether someone is looking at the screen.
struct FaceInfo {
    /// Normalized, top-left origin, mirrored like the hand points.
    var bounds: CGRect
    /// Degrees. 0 = facing the camera.
    var yaw: Double
    var pitch: Double
    /// Close enough and facing the screen (the camera sits on the screen's edge).
    var isFacingScreen: Bool
    /// Gap between the inner lips as a fraction of face height (only measured for faces facing
    /// the screen). Its frame-to-frame movement tells us whether this person is talking.
    var mouthOpen: CGFloat? = nil

    /// Lips are too few pixels to trust when the face is tiny in the frame.
    var mouthReliable: Bool { bounds.width >= 0.08 }
}

/// Everything Vision found in one camera frame. Picking whose hand drives the cursor
/// happens later, in `HandSelector`.
struct VisionFrame {
    var hands: [HandFrame]
    var faces: [FaceInfo]
    /// Frame width / height.
    var aspect: CGFloat
}

final class HandPoseAnalyzer {
    /// Thresholds for "looking at the screen". The camera sits above the display, so looking at
    /// the middle of the screen reads as a downward pitch.
    var maxYaw: Double = 30
    var pitchRange: ClosedRange<Double> = -40...25
    /// Minimum face width as a fraction of the frame — anyone smaller is too far away to be using this Mac.
    var minFaceWidth: CGFloat = 0.06
    /// Mac cameras deliver unmirrored frames, and data-output mirroring isn't always supported.
    /// When true, every point is flipped horizontally so moving your hand right moves the pointer right.
    var flipHorizontally = true

    /// Vision reports points for a request with a region of interest relative to that region.
    /// If the hand overlay ever draws offset from the real hand, flip this.
    private let roiResultsAreRelative = true

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        // Up to three hands so a second person can be seen — and deliberately ignored.
        r.maximumHandCount = 3
        return r
    }()

    private let landmarksRequest = VNDetectFaceLandmarksRequest()

    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        // Revision 3 reports yaw, pitch and roll.
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()

    func analyze(_ buffer: CVPixelBuffer) -> VisionFrame {
        let aspect = CGFloat(CVPixelBufferGetWidth(buffer)) / CGFloat(max(1, CVPixelBufferGetHeight(buffer)))
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])

        // Pass 1: faces over the whole frame.
        do { try handler.perform([faceRequest]) } catch { return VisionFrame(hands: [], faces: [], aspect: aspect) }
        let observations = faceRequest.results ?? []
        var faces = observations.map(faceInfo)

        // Lips for the (up to two) closest faces looking at the screen, for the speaker check.
        let facing = zip(observations, faces)
            .filter { $0.1.isFacingScreen }
            .map { $0.0 }
            .sorted { $0.boundingBox.width > $1.boundingBox.width }
        if !facing.isEmpty {
            landmarksRequest.inputFaceObservations = Array(facing.prefix(2))
            if (try? handler.perform([landmarksRequest])) != nil {
                for observed in landmarksRequest.results ?? [] {
                    guard let opening = Self.mouthOpening(observed) else { continue }
                    let b = observed.boundingBox
                    let center = CGPoint(x: b.midX, y: 1 - b.midY)
                    if let i = faces.indices.min(by: {
                        faces[$0].bounds.center.distance(to: center) < faces[$1].bounds.center.distance(to: center)
                    }) {
                        faces[i].mouthOpen = opening
                    }
                }
            }
        }

        // Pass 2: hands, cropped to the area around people facing the screen. A hand 10 ft away is
        // only a few pixels at the model's input size over the full frame; cropping makes it big.
        let roi = Self.handRegion(around: faces.filter(\.isFacingScreen))
        handRequest.regionOfInterest = CGRect(x: roi.minX, y: 1 - roi.maxY, width: roi.width, height: roi.height)
        var hands: [HandFrame] = []
        if (try? handler.perform([handRequest])) != nil {
            hands = (handRequest.results ?? []).compactMap { handFrame($0, roi: roi, aspect: aspect) }
        }
        guard flipHorizontally else { return VisionFrame(hands: hands, faces: faces, aspect: aspect) }
        return VisionFrame(hands: hands.map(Self.mirrored), faces: faces.map(Self.mirrored), aspect: aspect)
    }

    private static func mirrored(_ h: HandFrame) -> HandFrame {
        var m = h
        m.joints = h.joints.mapValues { CGPoint(x: 1 - $0.x, y: $0.y) }
        m.anchor = CGPoint(x: 1 - h.anchor.x, y: h.anchor.y)
        m.wrist = CGPoint(x: 1 - h.wrist.x, y: h.wrist.y)
        return m
    }

    private static func mirrored(_ f: FaceInfo) -> FaceInfo {
        var m = f
        m.bounds.origin.x = 1 - f.bounds.maxX
        m.yaw = -f.yaw
        return m
    }

    /// Union of generous boxes around each face (hands raised beside the head down to the chest).
    /// Falls back to the whole frame when nobody is facing the screen or people are close.
    static func handRegion(around faces: [FaceInfo]) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard !faces.isEmpty else { return full }
        var region = CGRect.null
        for f in faces {
            let w = f.bounds.width * 9
            let h = f.bounds.height * 7
            region = region.union(CGRect(x: f.bounds.midX - w / 2, y: f.bounds.midY - h * 0.45, width: w, height: h))
        }
        region = region.intersection(full)
        if region.isNull || region.width * region.height > 0.6 { return full }
        return region
    }

    /// Inner-lip height relative to the face box (landmark points are normalized to it).
    static func mouthOpening(_ face: VNFaceObservation) -> CGFloat? {
        guard let lips = face.landmarks?.innerLips ?? face.landmarks?.outerLips else { return nil }
        let ys = lips.normalizedPoints.map { $0.y }
        guard let low = ys.min(), let high = ys.max() else { return nil }
        return high - low
    }

    private func faceInfo(_ face: VNFaceObservation) -> FaceInfo {
        let yaw = (face.yaw?.doubleValue ?? 0) * 180 / .pi
        let pitch = (face.pitch?.doubleValue ?? 0) * 180 / .pi
        let b = face.boundingBox
        let bounds = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        let facing = b.width >= minFaceWidth && abs(yaw) <= maxYaw && pitchRange.contains(pitch)
        return FaceInfo(bounds: bounds, yaw: yaw, pitch: pitch, isFacingScreen: facing)
    }

    /// `roi` is in top-left normalized coordinates.
    private func handFrame(_ obs: VNHumanHandPoseObservation, roi: CGRect, aspect: CGFloat) -> HandFrame? {
        guard obs.confidence > 0.4, let points = try? obs.recognizedPoints(.all) else { return nil }

        var joints: [HandJoint: CGPoint] = [:]
        for j in HandJoint.allCases {
            if let p = points[j.visionName], p.confidence > 0.3 {
                var x = p.location.x
                var y = p.location.y
                if roiResultsAreRelative {
                    // Region-relative, bottom-left origin → full-frame, bottom-left origin.
                    x = roi.minX + x * roi.width
                    y = (1 - roi.maxY) + y * roi.height
                }
                // Flip to top-left origin.
                joints[j] = CGPoint(x: x, y: 1 - y)
            }
        }
        guard let wrist = joints[.wrist], let knuckle = joints[.middleMCP] else { return nil }

        // Distances in frame-height units so they mean the same thing on both axes.
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot((a.x - b.x) * aspect, a.y - b.y) }
        let palm = max(dist(wrist, knuckle), 0.0001)
        var pinch: CGFloat = 1
        if let t = joints[.thumbTip], let i = joints[.indexTip] {
            pinch = dist(t, i) / palm
        }
        return HandFrame(joints: joints,
                         confidence: obs.confidence,
                         anchor: knuckle,
                         wrist: wrist,
                         pinch: pinch,
                         palm: palm,
                         pose: Self.classify(joints, palm: palm, pinch: pinch),
                         chirality: Self.chirality(obs.chirality))
    }

    private static func chirality(_ c: VNChirality) -> HandChirality {
        switch c {
        case .left: return .left
        case .right: return .right
        default: return .unknown
        }
    }

    /// Rule-based poses on the landmarks. A finger counts as extended when its tip is
    /// meaningfully farther from the wrist than its middle joint.
    static func classify(_ j: [HandJoint: CGPoint], palm: CGFloat, pinch: CGFloat) -> HandPose {
        guard let w = j[.wrist] else { return .none }

        func extended(_ tip: HandJoint, _ pip: HandJoint) -> Bool? {
            guard let t = j[tip], let p = j[pip] else { return nil }
            return w.distance(to: t) > w.distance(to: p) * 1.12
        }

        guard let index = extended(.indexTip, .indexPIP),
              let middle = extended(.middleTip, .middlePIP),
              let ring = extended(.ringTip, .ringPIP),
              let little = extended(.littleTip, .littlePIP) else { return .other }

        var thumbOut = false
        if let tt = j[.thumbTip], let ip = j[.thumbIP], let imcp = j[.indexMCP] {
            thumbOut = w.distance(to: tt) > w.distance(to: ip) && tt.distance(to: imcp) > palm * 0.7
        }

        let count = [index, middle, ring, little].filter { $0 }.count

        if count == 4 && pinch > 0.45 { return .openPalm }
        if count == 0 {
            if thumbOut, let tt = j[.thumbTip], let imcp = j[.indexMCP], tt.y < imcp.y - palm * 0.35 {
                return .thumbsUp
            }
            return thumbOut ? .other : .fist
        }
        if index && middle && !ring && !little { return .victory }
        if index && !middle && !ring && !little { return .pointing }
        return .other
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat {
        hypot(x - p.x, y - p.y)
    }
}
