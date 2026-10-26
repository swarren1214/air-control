import Foundation

/// Debounces "is the person looking at the screen". Engages quickly, releases slowly,
/// so a glance down at a pan doesn't drop the cursor but walking past never grabs it.
struct AttentionFilter {
    var engageDelay: TimeInterval = 0.15
    var releaseDelay: TimeInterval = 0.6

    private(set) var isAttentive = false
    private var changeSince: TimeInterval?

    mutating func update(facing: Bool, at t: TimeInterval) -> Bool {
        if facing == isAttentive {
            changeSince = nil
            return isAttentive
        }
        let since = changeSince ?? t
        changeSince = since
        if t - since >= (facing ? engageDelay : releaseDelay) {
            isAttentive = facing
            changeSince = nil
        }
        return isAttentive
    }

    mutating func reset() {
        isAttentive = false
        changeSince = nil
    }
}
