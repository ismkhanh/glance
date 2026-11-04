import CoreGraphics
import Foundation

struct TrialResult: Codable {
    var target: Int       // box that lit up (0 = top-left, row by row)
    var picked: Int       // box the app chose (most votes over 1 s), -1 = none
    var frames: Int       // frames with a gaze estimate
    var hitFrames: Int    // frames that landed in the right box
}

struct TestSummary: Codable {
    var date: String
    var testNumber: Int
    var testType: String          // "absolute": the box under the gaze point; "steer": focus moved by eye + head shifts
    var screenPoints: [Double]
    var camera: String
    var fps: Double
    var featureSet: String
    var heldOutErrorPx: [String: Double]
    var calibrationSamples: Int
    var clicksUsed: Int           // clicks used to correct drift since the last calibration
    var offsetPx: [Double]        // the drift correction those clicks produced
    var grid: String
    var trials: Int
    var correct: Int
    var accuracy: Double
    var frameAccuracy: Double
    var perTrial: [TrialResult]
}

/// Keeps every calibration, click and test frame (settle time included), so the data can be studied
/// later without running again. predX/predY are the gaze estimate after drift correction, before smoothing.
final class RunLog {
    private var rows: [String] = []
    private let stamp: String

    static let header = "phase,round,targetIndex,targetX,targetY,cell,t,faceFound,blink,"
        + GazeFeatures.csvHeader + ",predX,predY"

    init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        stamp = formatter.string(from: Date())
    }

    /// results/ in the folder `swift run` was started from (the Glance folder).
    var folder: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("results", isDirectory: true)
    }

    func add(phase: String, round: Int, targetIndex: Int, target: CGPoint, cell: Int,
             time: Double, features: GazeFeatures?, prediction: CGPoint?) {
        let head = [
            phase,
            String(round),
            String(targetIndex),
            String(format: "%.1f", Double(target.x)),
            String(format: "%.1f", Double(target.y)),
            String(cell),
            String(format: "%.4f", time),
            features == nil ? "0" : "1",
            (features?.isBlink ?? false) ? "1" : "0",
        ].joined(separator: ",")
        let feats = features?.csvFields ?? GazeFeatures.emptyCSVFields
        var pred = ","
        if let p = prediction {
            pred = String(format: "%.1f,%.1f", Double(p.x), Double(p.y))
        }
        rows.append(head + "," + feats + "," + pred)
    }

    /// Writes the summary (JSON) and all frames so far (CSV). Returns the JSON file URL.
    func save(summary: TestSummary) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "gaze-\(stamp)-test\(summary.testNumber)"

        let csv = ([RunLog.header] + rows).joined(separator: "\n") + "\n"
        try csv.write(to: folder.appendingPathComponent(name + ".csv"), atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonURL = folder.appendingPathComponent(name + ".json")
        try encoder.encode(summary).write(to: jsonURL)
        return jsonURL
    }
}
