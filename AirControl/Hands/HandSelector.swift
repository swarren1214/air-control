import CoreGraphics
import Foundation

struct HandSelection {
    /// The one hand allowed to drive the cursor this frame, if any.
    var hand: HandFrame?
    /// The face that belongs to that hand (or the most likely viewer when nobody owns the cursor).
    var face: FaceInfo?
    /// Hands that are visible but ignored.
    var ignored: [HandFrame]
    var isLocked: Bool
    /// The owner's other hand, for two-hand gestures. Never someone else's hand.
    var partner: HandFrame? = nil
}

/// One cursor, one owner. The first person who raises an open palm while facing the screen
/// claims it; everyone else is ignored until that hand can't be tracked for `releaseAfter`.
/// The owner's other hand rides along as the `partner`, for two-hand gestures.
struct HandSelector {
    var releaseAfter: TimeInterval = 0.6
    var twoHanded = true

    private var lockPoint: CGPoint?
    private var lockPalm: CGFloat = 0.1
    private var lastSeen: TimeInterval = 0
    private var partnerPoint: CGPoint?
    private var partnerSeen: TimeInterval = 0

    var isLocked: Bool { lockPoint != nil }

    mutating func reset() {
        lockPoint = nil
        partnerPoint = nil
    }

    mutating func select(hands: [HandFrame], faces: [FaceInfo], requireFacing: Bool = true, at t: TimeInterval) -> HandSelection {
        if let lp = lockPoint {
            // Follow the owner frame to frame: the nearest hand within a plausible jump.
            let allowed = max(0.12, lockPalm * 2.5)
            if let i = Self.nearest(to: lp, in: hands), hands[i].anchor.distance(to: lp) <= allowed {
                return claim(i, in: hands, faces: faces, at: t)
            }
            if t - lastSeen <= releaseAfter {
                // Owner briefly lost (occluded by a pan, motion blur): keep the lock, ignore everyone else.
                return HandSelection(hand: nil, face: Self.face(near: lp, in: faces), ignored: hands, isLocked: true)
            }
            lockPoint = nil
            partnerPoint = nil
        }

        // Nobody owns the cursor: the first open palm from someone facing the screen claims it.
        // If two qualify in the same frame, the closer (larger) hand wins.
        var best: Int?
        for (i, hand) in hands.enumerated() where hand.pose == .openPalm {
            if requireFacing, Self.face(near: hand.wrist, in: faces)?.isFacingScreen != true { continue }
            if let b = best, hands[b].palm >= hand.palm { continue }
            best = i
        }
        if let b = best {
            return claim(b, in: hands, faces: faces, at: t)
        }

        let viewer = faces.filter(\.isFacingScreen).max { $0.bounds.width < $1.bounds.width }
            ?? faces.max { $0.bounds.width < $1.bounds.width }
        return HandSelection(hand: nil, face: viewer, ignored: hands, isLocked: false)
    }

    private mutating func claim(_ index: Int, in hands: [HandFrame], faces: [FaceInfo], at t: TimeInterval) -> HandSelection {
        let hand = hands[index]
        lockPoint = hand.anchor
        lockPalm = hand.palm
        lastSeen = t
        var others = hands
        others.remove(at: index)
        var partner: HandFrame?
        if twoHanded, let i = pickPartner(for: hand, in: others, faces: faces, at: t) {
            partner = others.remove(at: i)
        } else if !twoHanded {
            partnerPoint = nil
        }
        return HandSelection(hand: hand, face: Self.face(near: hand.wrist, in: faces), ignored: others,
                             isLocked: true, partner: partner)
    }

    /// The owner's other hand: about the same size (same distance from the camera), the opposite
    /// hand when Vision can tell, near enough to belong to the same body, and — when several
    /// people are in view — closest to the owner's face rather than someone else's.
    private mutating func pickPartner(for owner: HandFrame, in hands: [HandFrame], faces: [FaceInfo], at t: TimeInterval) -> Int? {
        guard !hands.isEmpty else {
            if t - partnerSeen > releaseAfter { partnerPoint = nil }
            return nil
        }
        let ownerFace = Self.face(near: owner.wrist, in: faces)

        func plausible(_ h: HandFrame) -> Bool {
            let gap = h.anchor.distance(to: owner.anchor)
            guard gap > owner.palm * 0.8, gap < owner.palm * 10 else { return false }
            let ratio = h.palm / max(owner.palm, 0.0001)
            guard ratio > 0.55, ratio < 1.8 else { return false }
            if h.chirality != .unknown, owner.chirality != .unknown, h.chirality == owner.chirality { return false }
            if faces.count > 1, let mine = ownerFace, let theirs = Self.face(near: h.wrist, in: faces),
               theirs.bounds != mine.bounds {
                return false
            }
            return true
        }

        // Keep following the same partner frame to frame.
        if let pp = partnerPoint, t - partnerSeen <= releaseAfter,
           let i = Self.nearest(to: pp, in: hands),
           hands[i].anchor.distance(to: pp) <= max(0.12, owner.palm * 2.5), plausible(hands[i]) {
            partnerPoint = hands[i].anchor
            partnerSeen = t
            return i
        }

        let candidates = hands.indices.filter { plausible(hands[$0]) }
        if let i = candidates.min(by: { abs(hands[$0].palm - owner.palm) < abs(hands[$1].palm - owner.palm) }) {
            partnerPoint = hands[i].anchor
            partnerSeen = t
            return i
        }
        if t - partnerSeen > releaseAfter { partnerPoint = nil }
        return nil
    }

    private static func nearest(to p: CGPoint, in hands: [HandFrame]) -> Int? {
        hands.indices.min { hands[$0].anchor.distance(to: p) < hands[$1].anchor.distance(to: p) }
    }

    /// The face most likely attached to a hand: horizontally closest, preferring faces above it.
    static func face(near p: CGPoint, in faces: [FaceInfo]) -> FaceInfo? {
        func score(_ f: FaceInfo) -> CGFloat {
            abs(f.bounds.midX - p.x) + 0.5 * max(0, f.bounds.midY - p.y)
        }
        return faces.min { score($0) < score($1) }
    }
}
