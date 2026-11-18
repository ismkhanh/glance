import AppKit
import CoreImage
import Foundation
import ScreenCaptureKit

/// The Mac's main display as a stream of JPEG frames for the headset's virtual screen.
/// ScreenCaptureKit does the capture; frames are scaled down and sent about eight times a second,
/// which reads clearly at panel size and keeps Wi-Fi use modest.
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFrame: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "glance.screenstream")
    private let context = CIContext()
    private var running = false

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.running else { return }
            self.running = true
            Task { await self.begin() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.running else { return }
            self.running = false
            let s = self.stream
            self.stream = nil
            Task { try? await s?.stopCapture() }
        }
    }

    private func begin() async {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            onError?("Screen Recording is off for your terminal app. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Glance.")
            queue.async { self.running = false }
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                onError?("No display found to stream.")
                queue.async { self.running = false }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1.0, 1152.0 / Double(display.width))
            config.width = max(320, Int(Double(display.width) * scale))
            config.height = max(200, Int(Double(display.height) * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 3
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            queue.async { self.stream = s }
            print("Quest screen: streaming the main display (\(config.width)x\(config.height)).")
        } catch {
            onError?("Could not stream the screen: \(error.localizedDescription)")
            queue.async { self.running = false }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55]) else { return }
        onFrame?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Screen stream stopped: \(error.localizedDescription)")
        queue.async { self.running = false; self.stream = nil }
    }
}
