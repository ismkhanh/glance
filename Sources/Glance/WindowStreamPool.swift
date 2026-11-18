import AppKit
import CoreImage
import Foundation
import ScreenCaptureKit

/// Frames for the floating window panels: the highlighted window as a live stream, every other panel as a
/// slowly refreshed still. One live stream only, because JPEG decode on the Quest is the bottleneck.
/// Frames come out tagged with the window id; QuestHub wraps them in "W" packets.
final class WindowStreamPool: @unchecked Sendable {
    var onFrame: ((UInt32, Data) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "glance.windowpool")
    private var running = false
    private var ids: [UInt32] = []
    private var highlighted: UInt32?
    private var live: WindowLiveStream?
    private var thumbTask: Task<Void, Never>?
    private var generation = 0

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.restartLive()
            self.thumbTask = Task { [weak self] in await self?.thumbnailLoop() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.generation += 1
            self.live?.stop()
            self.live = nil
            self.thumbTask?.cancel()
            self.thumbTask = nil
        }
    }

    func setWindows(_ newIDs: [UInt32]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ids = newIDs
            if let h = self.highlighted, !newIDs.contains(h) {
                self.highlighted = newIDs.first
                self.restartLive()
            }
        }
    }

    func setHighlighted(_ id: UInt32) {
        queue.async { [weak self] in
            guard let self, self.highlighted != id else { return }
            self.highlighted = id
            if self.running { self.restartLive() }
        }
    }

    /// Looking at nothing: stop the live stream instead of burning Quest decode on an unwatched window.
    func clearHighlight() {
        queue.async { [weak self] in
            guard let self else { return }
            self.highlighted = nil
            self.generation += 1
            self.live?.stop()
            self.live = nil
        }
    }

    // MARK: - Live stream (highlighted window)

    private func restartLive() {
        generation += 1
        let gen = generation
        live?.stop()
        live = nil
        guard running, let id = highlighted ?? ids.first else { return }
        highlighted = id
        let stream = WindowLiveStream(windowID: id) { [weak self] jpeg in
            self?.onFrame?(id, jpeg)
        } onError: { [weak self] message in
            self?.onError?(message)
        }
        live = stream
        stream.start(generation: gen, isCurrent: { [weak self] in
            self?.queue.sync { self?.generation == gen } ?? false
        })
    }

    // MARK: - Thumbnails (all other panels, staggered stills)

    private func thumbnailLoop() async {
        var cursor = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(300))
            let (runningNow, thumbs): (Bool, [UInt32]) = queue.sync {
                (self.running, self.ids.filter { $0 != self.highlighted })
            }
            guard runningNow, !thumbs.isEmpty else { continue }
            let id = thumbs[cursor % thumbs.count]
            cursor += 1
            if #available(macOS 14.0, *) {
                if let jpeg = try? await WindowCapture.jpeg(windowID: CGWindowID(id), maxWidth: 480) {
                    // Drop stills for windows that closed or became highlighted while capturing.
                    let stillWanted: Bool = queue.sync { self.running && self.ids.contains(id) && self.highlighted != id }
                    if stillWanted { onFrame?(id, jpeg) }
                }
            }
        }
    }
}

/// One window as a live JPEG stream (highlighted panel only, about 8 frames a second, at most 960 px wide).
private final class WindowLiveStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onJpeg: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private let windowID: UInt32
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "glance.windowlive")
    private let context = CIContext()
    private var running = false

    init(windowID: UInt32, onJpeg: @escaping (Data) -> Void, onError: @escaping (String) -> Void) {
        self.windowID = windowID
        self.onJpeg = onJpeg
        self.onError = onError
        super.init()
    }

    func start(generation: Int, isCurrent: @escaping () -> Bool) {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            Task { [weak self] in await self?.begin(isCurrent: isCurrent) }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            let s = self.stream
            self.stream = nil
            Task { try? await s?.stopCapture() }
        }
    }

    private func begin(isCurrent: @escaping () -> Bool) async {
        guard #available(macOS 14.0, *) else {
            onError?("Floating windows need macOS 14 or later.")
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            onError?("Screen Recording is off for your terminal app. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Glance.")
            queue.async { self.running = false }
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
                queue.async { self.running = false }
                return // window closed before its stream started; the roster will catch up
            }
            guard isCurrent() else { queue.async { self.running = false }; return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = min(1.0, 960.0 / max(1.0, Double(window.frame.width)))
            config.width = max(160, Int(window.frame.width * scale))
            config.height = max(120, Int(window.frame.height * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 3
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            queue.async { [weak self] in
                if self?.running == true { self?.stream = s } else { Task { try? await s.stopCapture() } }
            }
        } catch {
            onError?("Could not stream a window: \(error.localizedDescription)")
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
        onJpeg?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.running = false; self.stream = nil }
    }
}
