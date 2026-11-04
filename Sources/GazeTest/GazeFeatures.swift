import CoreGraphics
import Foundation

/// What we measure about the face in one camera frame.
///
/// Eye positions are normalised inside each eye's outline:
/// (0, 0) is the bottom-left corner of the eye box and (1, 1) the top-right.
struct GazeFeatures {
    var visL: CGPoint      // Apple Vision's pupil point, left eye
    var visR: CGPoint      // Apple Vision's pupil point, right eye
    var darkL: CGPoint     // centre of the darkest pixels inside the left eye (our own pupil finder)
    var darkR: CGPoint     // same, right eye
    var darkOK: Bool       // false when our pupil finder could not run on this frame
    var noseDX: Double     // nose position relative to the eyes, divided by eye distance (head turn)
    var noseDY: Double     // same, up and down (head tilt)
    var faceX: Double      // face centre in the camera image, 0...1
    var faceY: Double
    var faceSize: Double   // face width in the camera image, 0...1 (distance to the screen)
    var yaw: Double        // Vision head angles in radians, NaN when not given
    var pitch: Double
    var openness: Double   // eye height / eye width; small means a blink

    var visAvg: CGPoint { CGPoint(x: (visL.x + visR.x) / 2, y: (visL.y + visR.y) / 2) }
    var darkAvg: CGPoint { CGPoint(x: (darkL.x + darkR.x) / 2, y: (darkL.y + darkR.y) / 2) }
    var isBlink: Bool { openness < 0.14 }

    static let csvHeader =
        "darkOK,visLX,visLY,visRX,visRY,darkLX,darkLY,darkRX,darkRY,noseDX,noseDY,faceX,faceY,faceSize,yaw,pitch,openness"

    /// 17 fields, matching `csvHeader`.
    var csvFields: String {
        let values: [Double] = [
            Double(visL.x), Double(visL.y), Double(visR.x), Double(visR.y),
            Double(darkL.x), Double(darkL.y), Double(darkR.x), Double(darkR.y),
            noseDX, noseDY, faceX, faceY, faceSize, yaw, pitch, openness,
        ]
        return (darkOK ? "1" : "0") + "," + values.map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    /// 17 empty fields, for frames with no face.
    static let emptyCSVFields = Array(repeating: "", count: 17).joined(separator: ",")
}
