import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import Vision

/// Camera → Apple Vision face landmarks → GazeFeatures, one per frame.
/// Frames are processed on this Mac and thrown away; nothing is uploaded.
final class GazeEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// Called on the main thread for every frame. Features are nil when no face was found.
    var onFeatures: ((GazeFeatures?, Double) -> Void)?
    /// Camera name and frame size, for the results file. Main thread only.
    private(set) var cameraInfo = "not started"

    private let queue = DispatchQueue(label: "glance.camera")
    private let request = VNDetectFaceLandmarksRequest()
    private var deviceName = ""
    private var reportedSize = false

    static let deniedMessage =
        "Camera access is off. Turn it on in System Settings > Privacy & Security > Camera for Terminal (or Xcode), then run again."

    /// Asks for camera access if needed, then starts the camera. `completion` runs on the main thread
    /// with nil on success, or a message for the user.
    func start(completion: @escaping (String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configure(completion)
                    } else {
                        completion(GazeEngine.deniedMessage)
                    }
                }
            }
        default:
            completion(GazeEngine.deniedMessage)
        }
    }

    private func configure(_ completion: @escaping (String?) -> Void) {
        queue.async {
            let error = self.setUpSession()
            DispatchQueue.main.async { completion(error) }
        }
    }

    private func setUpSession() -> String? {
        // Prefer the built-in camera, so an iPhone (Continuity Camera) is not picked by accident.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else { return "No camera found." }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return "Could not open the camera." }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return "Could not use the camera."
        }
        session.addInput(input)
        // More pixels on the eyes = a steadier pupil position.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return "Could not read camera frames."
        }
        session.addOutput(output)
        session.commitConfiguration()

        deviceName = device.localizedName
        session.startRunning()
        return nil
    }

    // MARK: - Frames (camera queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CACurrentMediaTime()

        if !reportedSize {
            reportedSize = true
            let info = "\(deviceName), \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
            DispatchQueue.main.async { self.cameraInfo = info }
        }

        let features = extract(from: pixelBuffer)
        DispatchQueue.main.async { self.onFeatures?(features, time) }
    }

    private func extract(from pixelBuffer: CVPixelBuffer) -> GazeFeatures? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let faces = request.results as? [VNFaceObservation],
              let face = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
              let leftPupil = landmarks.leftPupil, let rightPupil = landmarks.rightPupil,
              let nose = landmarks.nose
        else { return nil }

        // Vision image points: origin at the bottom-left, in pixels.
        let size = CGSize(width: width, height: height)
        let nosePoints = nose.pointsInImage(imageSize: size)
        guard let leftBox = EyeBox(leftEye.pointsInImage(imageSize: size)),
              let rightBox = EyeBox(rightEye.pointsInImage(imageSize: size)),
              let leftPupilPoint = leftPupil.pointsInImage(imageSize: size).first,
              let rightPupilPoint = rightPupil.pointsInImage(imageSize: size).first,
              !nosePoints.isEmpty
        else { return nil }

        let visL = leftBox.normalise(leftPupilPoint)
        let visR = rightBox.normalise(rightPupilPoint)

        // Our own pupil finder: centre of the darkest pixels inside each eye.
        var darkL = visL
        var darkR = visR
        var darkOK = false
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            if let dl = leftBox.darkCentre(bytes: bytes, bytesPerRow: bytesPerRow, imageWidth: width, imageHeight: height),
               let dr = rightBox.darkCentre(bytes: bytes, bytesPerRow: bytesPerRow, imageWidth: width, imageHeight: height) {
                darkL = dl
                darkR = dr
                darkOK = true
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        let eyeMidX = Double(leftBox.mid.x + rightBox.mid.x) / 2
        let eyeMidY = Double(leftBox.mid.y + rightBox.mid.y) / 2
        let eyeDistance = max(1.0, hypot(Double(leftBox.mid.x - rightBox.mid.x), Double(leftBox.mid.y - rightBox.mid.y)))
        let noseX = nosePoints.reduce(0.0) { $0 + Double($1.x) } / Double(nosePoints.count)
        let noseY = nosePoints.reduce(0.0) { $0 + Double($1.y) } / Double(nosePoints.count)

        return GazeFeatures(
            visL: visL,
            visR: visR,
            darkL: darkL,
            darkR: darkR,
            darkOK: darkOK,
            noseDX: (noseX - eyeMidX) / eyeDistance,
            noseDY: (noseY - eyeMidY) / eyeDistance,
            faceX: Double(face.boundingBox.midX),
            faceY: Double(face.boundingBox.midY),
            faceSize: Double(face.boundingBox.width),
            yaw: face.yaw?.doubleValue ?? .nan,
            pitch: face.pitch?.doubleValue ?? .nan,
            openness: (leftBox.openness + rightBox.openness) / 2
        )
    }
}

/// The bounding box of one eye's outline, in Vision image points (origin bottom-left).
struct EyeBox {
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat

    init?(_ points: [CGPoint]) {
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
              x1 - x0 > 4, y1 - y0 > 1 else { return nil }
        minX = x0
        maxX = x1
        minY = y0
        maxY = y1
    }

    var boxWidth: CGFloat { maxX - minX }
    var boxHeight: CGFloat { maxY - minY }
    var mid: CGPoint { CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    var openness: Double { Double(boxHeight / boxWidth) }

    func normalise(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - minX) / boxWidth, y: (p.y - minY) / boxHeight)
    }

    /// Centre of the darkest 20% of pixels inside an ellipse in the eye box (the iris and pupil).
    /// Vision points start at the bottom-left; pixel rows start at the top, so rows are flipped.
    func darkCentre(bytes: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, imageWidth: Int, imageHeight: Int) -> CGPoint? {
        let cx = mid.x
        let cy = mid.y
        let ax = boxWidth * 0.45
        let ay = boxHeight * 0.40
        let x0 = max(0, Int(minX.rounded(.down)))
        let x1 = min(imageWidth - 1, Int(maxX.rounded(.up)))
        let y0 = max(0, Int(minY.rounded(.down)))
        let y1 = min(imageHeight - 1, Int(maxY.rounded(.up)))
        guard x0 < x1, y0 < y1, ax > 0, ay > 0 else { return nil }

        var pixels: [(lum: Int, x: Int, y: Int)] = []
        pixels.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for y in y0...y1 {
            let dy = (CGFloat(y) - cy) / ay
            let row = imageHeight - 1 - y
            for x in x0...x1 {
                let dx = (CGFloat(x) - cx) / ax
                if dx * dx + dy * dy > 1 { continue }
                let p = row * bytesPerRow + x * 4   // BGRA
                let lum = (Int(bytes[p + 2]) * 299 + Int(bytes[p + 1]) * 587 + Int(bytes[p]) * 114) / 1000
                pixels.append((lum: lum, x: x, y: y))
            }
        }
        guard pixels.count >= 20 else { return nil }

        let sorted = pixels.map { $0.lum }.sorted()
        let threshold = sorted[sorted.count / 5]
        var sx = 0.0
        var sy = 0.0
        var n = 0.0
        for px in pixels where px.lum <= threshold {
            sx += Double(px.x)
            sy += Double(px.y)
            n += 1
        }
        guard n > 0 else { return nil }
        return normalise(CGPoint(x: sx / n, y: sy / n))
    }
}
