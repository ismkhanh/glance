import CoreGraphics
import Foundation

/// A choice of which measurements the model uses.
struct FeatureSet {
    let name: String
    let needsDark: Bool
    let extract: (GazeFeatures) -> [Double]

    func usable(_ f: GazeFeatures) -> Bool { !f.isBlink && (!needsDark || f.darkOK) }

    /// Calibration tries all of these and keeps the one that works best on dots it did not train on.
    /// All of them use the eyelid: when you look down the lid comes down, which is the strongest
    /// up/down signal a webcam sees. Face position is left out on purpose: it fits the calibration
    /// well but breaks as soon as you move in your chair (tested on the 31 Oct recordings).
    static let candidates: [FeatureSet] = [
        FeatureSet(name: "Vision pupils + eyelids", needsDark: false, extract: { f in
            let v = f.visAvg
            return [Double(v.x), Double(v.y), f.openness]
        }),
        FeatureSet(name: "both pupils + eyelids", needsDark: true, extract: { f in
            let v = f.visAvg
            let d = f.darkAvg
            return [Double(v.x), Double(v.y), Double(d.x), Double(d.y), f.openness]
        }),
        FeatureSet(name: "Vision pupils + eyelids + head", needsDark: false, extract: { f in
            let v = f.visAvg
            return [Double(v.x), Double(v.y), f.openness, f.noseDX, f.noseDY]
        }),
        FeatureSet(name: "both pupils + eyelids + head", needsDark: true, extract: { f in
            let v = f.visAvg
            let d = f.darkAvg
            return [Double(v.x), Double(v.y), Double(d.x), Double(d.y), f.openness, f.noseDX, f.noseDY]
        }),
    ]
}

/// Linear ridge regression from features to a screen point (in view points).
struct RidgeModel {
    let mean: [Double]
    let scale: [Double]
    let wx: [Double]   // [bias, w1, w2, ...]
    let wy: [Double]

    func predict(_ x: [Double]) -> CGPoint {
        var px = wx[0]
        var py = wy[0]
        for i in 0..<x.count {
            let z = (x[i] - mean[i]) / scale[i]
            px += wx[i + 1] * z
            py += wy[i + 1] * z
        }
        return CGPoint(x: px, y: py)
    }

    static func fit(_ xs: [[Double]], targets: [CGPoint], lambda: Double = 1.0) -> RidgeModel? {
        guard let d = xs.first?.count, d > 0, xs.count > d + 1, xs.count == targets.count else { return nil }
        let n = Double(xs.count)

        var mean = [Double](repeating: 0, count: d)
        for x in xs { for i in 0..<d { mean[i] += x[i] } }
        for i in 0..<d { mean[i] /= n }

        var scale = [Double](repeating: 0, count: d)
        for x in xs {
            for i in 0..<d {
                let v = x[i] - mean[i]
                scale[i] += v * v
            }
        }
        for i in 0..<d { scale[i] = max((scale[i] / n).squareRoot(), 1e-6) }

        let m = d + 1
        var ata = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        var atx = [Double](repeating: 0, count: m)
        var aty = [Double](repeating: 0, count: m)
        for (k, x) in xs.enumerated() {
            var row = [1.0]
            for i in 0..<d { row.append((x[i] - mean[i]) / scale[i]) }
            let tx = Double(targets[k].x)
            let ty = Double(targets[k].y)
            for a in 0..<m {
                atx[a] += row[a] * tx
                aty[a] += row[a] * ty
                for b in 0..<m { ata[a][b] += row[a] * row[b] }
            }
        }
        for a in 1..<m { ata[a][a] += lambda }   // do not shrink the bias

        guard let wx = solve(ata, atx), let wy = solve(ata, aty) else { return nil }
        return RidgeModel(mean: mean, scale: scale, wx: wx, wy: wy)
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var v = b
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            if abs(m[pivot][col]) < 1e-12 { return nil }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for r in 0..<n where r != col {
                let factor = m[r][col] / m[col][col]
                if factor == 0 { continue }
                for c in col..<n { m[r][c] -= factor * m[col][c] }
                v[r] -= factor * v[col]
            }
        }
        return (0..<n).map { v[$0] / m[$0][$0] }
    }
}

struct CalSample {
    let pointIndex: Int
    let target: CGPoint
    let features: GazeFeatures
}

struct CalibrationResult {
    let set: FeatureSet
    let model: RidgeModel
    let bestError: Double                 // average px error on dots left out of training
    let heldOutErrors: [String: Double]   // the same, for every candidate
    let sampleCount: Int
}

enum Calibrator {
    /// Leave-one-dot-out: for each dot, train on the other dots and measure the error on it.
    /// This tells us how well each feature set works on screen positions it has not seen.
    static func fit(_ samples: [CalSample]) -> CalibrationResult? {
        var errors: [String: Double] = [:]
        var best: (set: FeatureSet, error: Double)?

        for set in FeatureSet.candidates {
            let usable = samples.filter { set.usable($0.features) }
            let points = Set(usable.map { $0.pointIndex })
            guard points.count >= 6 else { continue }

            var total = 0.0
            var count = 0.0
            var failed = false
            for k in points {
                let train = usable.filter { $0.pointIndex != k }
                let test = usable.filter { $0.pointIndex == k }
                guard let model = RidgeModel.fit(train.map { set.extract($0.features) }, targets: train.map { $0.target }) else {
                    failed = true
                    break
                }
                for s in test {
                    let p = model.predict(set.extract(s.features))
                    total += hypot(Double(p.x - s.target.x), Double(p.y - s.target.y))
                    count += 1
                }
            }
            guard !failed, count > 0 else { continue }
            let error = total / count
            guard error.isFinite else { continue }
            errors[set.name] = error.rounded()
            if let current = best {
                if error < current.error { best = (set: set, error: error) }
            } else {
                best = (set: set, error: error)
            }
        }

        guard let chosen = best else { return nil }
        let usable = samples.filter { chosen.set.usable($0.features) }
        guard let model = RidgeModel.fit(usable.map { chosen.set.extract($0.features) }, targets: usable.map { $0.target }) else {
            return nil
        }
        return CalibrationResult(set: chosen.set, model: model, bestError: chosen.error,
                                 heldOutErrors: errors, sampleCount: usable.count)
    }
}
