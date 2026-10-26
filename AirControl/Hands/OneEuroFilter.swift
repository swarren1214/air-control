import Foundation

/// 1€ filter (Casiez, Roussel, Vogel 2012): smooths jitter when the hand is still,
/// stays responsive when it moves fast.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double

    private var x = LowPass()
    private var dx = LowPass()
    private var lastTime: TimeInterval?
    private var lastRaw: Double?

    init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func filter(_ value: Double, at t: TimeInterval) -> Double {
        var dt = 1.0 / 30.0
        if let lt = lastTime, t > lt { dt = t - lt }
        lastTime = t

        let rawDerivative = lastRaw.map { (value - $0) / dt } ?? 0
        lastRaw = value
        let edx = dx.filter(rawDerivative, alpha: Self.alpha(cutoff: dCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(edx)
        return x.filter(value, alpha: Self.alpha(cutoff: cutoff, dt: dt))
    }

    mutating func reset() {
        x = LowPass()
        dx = LowPass()
        lastTime = nil
        lastRaw = nil
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    private struct LowPass {
        var y: Double?
        mutating func filter(_ value: Double, alpha: Double) -> Double {
            guard let prev = y else { y = value; return value }
            let v = alpha * value + (1 - alpha) * prev
            y = v
            return v
        }
    }
}
