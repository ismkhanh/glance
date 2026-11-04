import Foundation

/// One Euro filter: smooths a noisy signal but follows fast moves quickly.
/// Paper: Casiez, Roussel, Vogel, CHI 2012.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double = 1.0

    private var previous: Double?
    private var previousDerivative: Double = 0
    private var previousTime: Double = 0

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func filter(_ value: Double, t: Double) -> Double {
        guard let last = previous else {
            previous = value
            previousTime = t
            return value
        }
        let dt = max(t - previousTime, 0.001)
        let derivative = (value - last) / dt
        let aD = OneEuroFilter.alpha(cutoff: derivativeCutoff, dt: dt)
        let smoothDerivative = aD * derivative + (1 - aD) * previousDerivative
        let cutoff = minCutoff + beta * abs(smoothDerivative)
        let a = OneEuroFilter.alpha(cutoff: cutoff, dt: dt)
        let smooth = a * value + (1 - a) * last
        previous = smooth
        previousDerivative = smoothDerivative
        previousTime = t
        return smooth
    }

    mutating func reset() {
        previous = nil
        previousDerivative = 0
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
