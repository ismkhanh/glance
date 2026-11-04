import AppKit
import AVFoundation
import QuartzCore

/// Full-screen view: calibration, drift correction by clicks, the box tests, and live views.
final class GazeView: NSView {
    enum Phase {
        case intro
        case calibrating(point: Int, start: Double)
        case testing(trial: Int, start: Double)
        case touchUp(dot: Int)
        case testDone
        case live
        case steerLive
    }

    enum TestKind: String {
        case absolute   // the box under the gaze point
        case steer      // focus moved by the direction of eye + head shifts
    }

    // Timing, in seconds
    private let calSettle = 0.7      // time for the eyes to land on a new dot
    private let calCollect = 1.1     // then we record
    private let trialSettle = 1.0
    private let trialCollect = 1.0
    private let passRate = 0.9
    private let touchUpDots = 5

    private let engine: GazeEngine
    private let previewView = NSView()
    private var timer: Timer?
    private var phase: Phase = .intro {
        didSet {
            if case .intro = phase { previewView.isHidden = false } else { previewView.isHidden = true }
        }
    }
    private var status = "Starting the camera…"
    private var lastFaceTime = -10.0
    private var frameTimes: [Double] = []

    // Calibration
    private var calPoints: [CGPoint] = []
    private var calSamples: [CalSample] = []
    private var calibration: CalibrationResult?
    private var calRound = 0

    // Drift correction from clicks: you look where you click
    private var offset = CGPoint.zero
    private var clicks = 0
    private var recent: [(t: Double, raw: CGPoint)] = []
    private var flash: (p: CGPoint, until: Double)?
    private var touchUpPoints: [CGPoint] = []

    // Gaze estimate: smooth for the absolute box, lightly smoothed for steering
    private var filterX = OneEuroFilter(minCutoff: 0.8, beta: 0.004)
    private var filterY = OneEuroFilter(minCutoff: 0.8, beta: 0.004)
    private var steerFX = OneEuroFilter(minCutoff: 1.5, beta: 0.01)
    private var steerFY = OneEuroFilter(minCutoff: 1.5, beta: 0.01)
    private var gaze: CGPoint?
    private var steerPoint: CGPoint?

    // Box tests
    private var testKind: TestKind = .absolute
    private var layout = Layout(cols: 2, rows: 2)
    private var testNumber = 0
    private var order: [Int] = []
    private var votes: [Int: Int] = [:]
    private var trialFrames = 0
    private var hitFrames = 0
    private var allFrames = 0
    private var allHitFrames = 0
    private var trials: [TrialResult] = []
    private var lastSummary: TestSummary?
    private var savedPath = ""

    // Steering
    private let steering = Steering(layout: Layout(cols: 2, rows: 2))
    private let liveLayout = Layout(cols: 3, rows: 2)
    private let liveNames = ["Terminal 1", "Terminal 2", "Chrome", "Music", "Notes", "Terminal 3"]

    private let log = RunLog()

    init(frame: NSRect, engine: GazeEngine) {
        self.engine = engine
        super.init(frame: frame)
        wantsLayer = true

        let preview = AVCaptureVideoPreviewLayer(session: engine.session)
        preview.videoGravity = .resizeAspect
        previewView.layer = preview
        previewView.wantsLayer = true
        previewView.frame = NSRect(x: frame.width - 360, y: 24, width: 336, height: 189)
        addSubview(previewView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var viewW: CGFloat { bounds.width }
    private var viewH: CGFloat { bounds.height }

    func attach(cameraError: String?) {
        engine.onFeatures = { [weak self] features, time in
            self?.handle(features, at: time)
        }
        status = cameraError ?? "Camera is on. Sit at your normal distance, with light on your face."
        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        needsDisplay = true
    }

    // MARK: - Camera frames (main thread)

    private func handle(_ features: GazeFeatures?, at time: Double) {
        frameTimes.append(time)
        if frameTimes.count > 30 { frameTimes.removeFirst(frameTimes.count - 30) }
        if features != nil { lastFaceTime = time }

        var raw: CGPoint?
        if let f = features, let cal = calibration, cal.set.usable(f) {
            let r = cal.model.predict(cal.set.extract(f))
            if r.x.isFinite && r.y.isFinite {
                raw = r
                recent.append((t: time, raw: r))
            }
        }
        while let first = recent.first, time - first.t > 1.0 { recent.removeFirst() }

        var corrected: CGPoint?
        if let r = raw {
            let c = CGPoint(x: r.x + offset.x, y: r.y + offset.y)
            corrected = c
            gaze = CGPoint(x: filterX.filter(Double(c.x), t: time), y: filterY.filter(Double(c.y), t: time))
            steerPoint = CGPoint(x: steerFX.filter(Double(c.x), t: time), y: steerFY.filter(Double(c.y), t: time))
        }
        let size = bounds.size

        switch phase {
        case .calibrating(let point, let start):
            let elapsed = time - start
            if elapsed >= calSettle && elapsed < calSettle + calCollect && point < calPoints.count {
                let target = calPoints[point]
                log.add(phase: "cal", round: calRound, targetIndex: point, target: target, cell: -1,
                        time: time, features: features, prediction: nil)
                if let f = features {
                    calSamples.append(CalSample(pointIndex: point, target: target, features: f))
                }
            }

        case .testing(let trial, let start):
            guard trial < order.count else { break }
            let elapsed = time - start
            guard elapsed >= 0 else { break }
            let target = order[trial]
            var picked = -1
            if testKind == .steer {
                if let s = steerPoint, raw != nil { steering.update(s, t: time, size: size) }
                picked = steering.focus
            } else if raw != nil, let g = gaze {
                picked = layout.index(at: g, in: size)
            }
            let collecting = elapsed >= trialSettle && elapsed < trialSettle + trialCollect
            if collecting && picked >= 0 {
                votes[picked, default: 0] += 1
                trialFrames += 1
                if picked == target { hitFrames += 1 }
            }
            let rect = layout.rect(target, in: size)
            let name = (testKind == .steer ? "steer" : "test") + layout.name + (collecting ? "" : "-settle")
            log.add(phase: name, round: testNumber, targetIndex: target,
                    target: CGPoint(x: rect.midX, y: rect.midY), cell: picked,
                    time: time, features: features, prediction: corrected)

        case .steerLive:
            if let s = steerPoint, raw != nil { steering.update(s, t: time, size: size) }

        default:
            break
        }
        needsDisplay = true
    }

    // MARK: - Clock (60 times a second)

    @objc private func timerFired() {
        let now = CACurrentMediaTime()
        switch phase {
        case .calibrating(let point, let start):
            if now - start >= calSettle + calCollect {
                if point + 1 < calPoints.count {
                    phase = .calibrating(point: point + 1, start: now)
                } else {
                    finishCalibration()
                }
            }
        case .testing(let trial, let start):
            if now - start >= trialSettle + trialCollect {
                finishTrial(trial)
                if trial + 1 < order.count {
                    phase = .testing(trial: trial + 1, start: now)
                } else {
                    finishTest()
                }
            }
        default:
            break
        }
        needsDisplay = true
    }

    // MARK: - Calibration

    private func makeCalPoints() -> [CGPoint] {
        let xs: [CGFloat] = [0.08, 0.5, 0.92]
        let ys: [CGFloat] = [0.92, 0.5, 0.08]   // top row first (view origin is bottom-left)
        var points: [CGPoint] = []
        for (row, fy) in ys.enumerated() {
            let rowXs: [CGFloat] = row % 2 == 0 ? xs : Array(xs.reversed())
            for fx in rowXs { points.append(CGPoint(x: fx * viewW, y: fy * viewH)) }
        }
        return points
    }

    private func resetFilters() {
        filterX.reset()
        filterY.reset()
        steerFX.reset()
        steerFY.reset()
    }

    private func startCalibration() {
        calPoints = makeCalPoints()
        calSamples = []
        calRound += 1
        calibration = nil
        gaze = nil
        steerPoint = nil
        offset = .zero
        clicks = 0
        recent = []
        resetFilters()
        NSCursor.setHiddenUntilMouseMoves(true)
        phase = .calibrating(point: 0, start: CACurrentMediaTime())
    }

    private func finishCalibration() {
        if let result = Calibrator.fit(calSamples) {
            calibration = result
            status = String(format: "Calibrated with %@: about %.0f px off on dots it did not train on. Press T or J to test.",
                            result.set.name, result.bestError)
        } else {
            status = "Calibration failed: not enough clear face frames. Check the light, then press C to try again."
        }
        resetFilters()
        phase = .intro
    }

    // MARK: - Drift correction by clicks

    /// The gap between where you clicked and the gaze estimate just before the click is the drift.
    /// We keep a running average of it and add it to every estimate.
    private func addClick(at p: CGPoint, time: Double) {
        guard calibration != nil else { return }
        let window = recent.filter { time - $0.t <= 0.4 && time - $0.t >= 0.05 }
        guard window.count >= 3 else { return }
        let mx = window.reduce(0.0) { $0 + Double($1.raw.x) } / Double(window.count)
        let my = window.reduce(0.0) { $0 + Double($1.raw.y) } / Double(window.count)
        let error = CGPoint(x: Double(p.x) - mx, y: Double(p.y) - my)
        if clicks == 0 {
            offset = error
        } else {
            offset = CGPoint(x: 0.5 * offset.x + 0.5 * error.x, y: 0.5 * offset.y + 0.5 * error.y)
        }
        clicks += 1
        flash = (p: p, until: time + 0.5)
        log.add(phase: "click", round: clicks, targetIndex: -1, target: p, cell: -1,
                time: time, features: nil, prediction: CGPoint(x: mx, y: my))
    }

    private func startTouchUp() {
        guard calibration != nil else {
            status = "Calibrate first: press C."
            return
        }
        touchUpPoints = (0..<touchUpDots).map { _ in
            CGPoint(x: CGFloat.random(in: 0.1...0.9) * viewW, y: CGFloat.random(in: 0.12...0.88) * viewH)
        }
        phase = .touchUp(dot: 0)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        switch phase {
        case .calibrating, .testing:
            return   // clicks do not count during calibration or a test
        case .touchUp(let dot):
            guard dot < touchUpPoints.count else { return }
            let target = touchUpPoints[dot]
            guard hypot(Double(p.x - target.x), Double(p.y - target.y)) < 60 else { return }
            addClick(at: target, time: now)
            if dot + 1 < touchUpPoints.count {
                phase = .touchUp(dot: dot + 1)
            } else {
                phase = .intro
                status = "Touch-up done: \(clicks) clicks are correcting drift. Press T or J to test."
            }
        default:
            addClick(at: p, time: now)
        }
        needsDisplay = true
    }

    // MARK: - Box tests

    private func makeOrder(cells: Int, repeats: Int) -> [Int] {
        let base = (0..<cells).flatMap { Array(repeating: $0, count: repeats) }
        for _ in 0..<200 {
            let s = base.shuffled()
            if zip(s, s.dropFirst()).allSatisfy({ $0 != $1 }) { return s }
        }
        return base.shuffled()
    }

    private func startTest(_ kind: TestKind, layout newLayout: Layout) {
        guard calibration != nil else {
            status = "Calibrate first: press C."
            return
        }
        testKind = kind
        layout = newLayout
        testNumber += 1
        order = makeOrder(cells: newLayout.count, repeats: newLayout.count == 4 ? 5 : 2)
        if kind == .steer {
            // Steering is relative, so it needs a starting box: one extra first round, not scored.
            order.insert((order[0] + 1) % newLayout.count, at: 0)
            steering.layout = newLayout
            steering.snapAfter = nil
            steering.reset(focus: order[0])
        }
        trials = []
        votes = [:]
        trialFrames = 0
        hitFrames = 0
        allFrames = 0
        allHitFrames = 0
        NSCursor.setHiddenUntilMouseMoves(true)
        phase = .testing(trial: 0, start: CACurrentMediaTime())
    }

    private func finishTrial(_ trial: Int) {
        defer {
            votes = [:]
            trialFrames = 0
            hitFrames = 0
        }
        guard trial < order.count else { return }
        if testKind == .steer && trial == 0 { return }   // the starting round is not scored
        let target = order[trial]
        let picked = votes.max(by: { $0.value < $1.value })?.key ?? -1
        trials.append(TrialResult(target: target, picked: picked, frames: trialFrames, hitFrames: hitFrames))
        allFrames += trialFrames
        allHitFrames += hitFrames
    }

    private func finishTest() {
        guard let cal = calibration else {
            phase = .intro
            return
        }
        let correct = trials.filter { $0.picked == $0.target }.count
        let summary = TestSummary(
            date: ISO8601DateFormatter().string(from: Date()),
            testNumber: testNumber,
            testType: testKind.rawValue,
            screenPoints: [Double(viewW), Double(viewH)],
            camera: engine.cameraInfo,
            fps: currentFPS,
            featureSet: cal.set.name,
            heldOutErrorPx: cal.heldOutErrors,
            calibrationSamples: cal.sampleCount,
            clicksUsed: clicks,
            offsetPx: [Double(offset.x).rounded(), Double(offset.y).rounded()],
            grid: layout.name,
            trials: trials.count,
            correct: correct,
            accuracy: trials.isEmpty ? 0 : Double(correct) / Double(trials.count),
            frameAccuracy: allFrames == 0 ? 0 : Double(allHitFrames) / Double(allFrames),
            perTrial: trials
        )
        lastSummary = summary
        do {
            savedPath = try log.save(summary: summary).path
        } catch {
            savedPath = "could not save: \(error.localizedDescription)"
        }
        phase = .testDone
    }

    private var currentFPS: Double {
        guard frameTimes.count > 1, let first = frameTimes.first, let last = frameTimes.last, last > first else { return 0 }
        return (Double(frameTimes.count - 1) / (last - first)).rounded()
    }

    private func startSteerLive() {
        guard calibration != nil else {
            status = "Calibrate first: press C."
            return
        }
        steering.layout = liveLayout
        steering.snapAfter = 1.2
        let start = gaze.map { liveLayout.index(at: $0, in: bounds.size) } ?? 0
        steering.reset(focus: max(0, start))
        phase = .steerLive
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            if case .intro = phase {
                NSApp.terminate(nil)
            } else {
                phase = .intro
                status = "Stopped. Pick a key below, or Esc to quit."
            }
            needsDisplay = true
            return
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "c":
            startCalibration()
        case "t":
            startTest(.absolute, layout: Layout(cols: 2, rows: 2))
        case "y":
            startTest(.absolute, layout: Layout(cols: 3, rows: 3))
        case "j":
            startTest(.steer, layout: Layout(cols: 2, rows: 2))
        case "k":
            startTouchUp()
        case "l":
            if calibration == nil {
                status = "Calibrate first: press C."
            } else {
                phase = .live
            }
        case "s":
            startSteerLive()
        case "q":
            NSApp.terminate(nil)
        default:
            super.keyDown(with: event)
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        NSBezierPath(rect: bounds).fill()
        let now = CACurrentMediaTime()

        switch phase {
        case .intro:
            drawIntro()
        case .calibrating(let point, let start):
            drawCalibration(point: point, elapsed: now - start)
        case .testing(let trial, _):
            drawTest(trial: trial)
        case .touchUp(let dot):
            drawTouchUp(dot: dot)
        case .testDone:
            drawResult()
        case .live:
            drawLive()
        case .steerLive:
            drawSteerLive()
        }

        if let f = flash, now < f.until {
            NSColor.systemGreen.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: f.p.x - 22, y: f.p.y - 22, width: 44, height: 44))
            ring.lineWidth = 3
            ring.stroke()
        }

        if now - lastFaceTime > 0.5 {
            drawText("No face found. Sit in front of the camera, with light on your face.",
                     at: CGPoint(x: viewW / 2, y: viewH * 0.3), size: 22, color: .systemRed,
                     weight: .semibold, centered: true)
        }
    }

    private func drawIntro() {
        var y = viewH - 90
        func line(_ s: String, size: CGFloat = 18, color: NSColor = .white, weight: NSFont.Weight = .regular) {
            drawText(s, at: CGPoint(x: 64, y: y), size: size, color: color, weight: weight)
            y -= size + 14
        }
        line("Glance: eye-tracking test", size: 32, weight: .bold)
        y -= 8
        line(status, color: NSColor(calibratedWhite: 0.85, alpha: 1))
        line("Camera: \(engine.cameraInfo), \(Int(currentFPS)) frames per second. Drift-correction clicks: \(clicks)",
             size: 15, color: .gray)
        y -= 20
        line("C     Calibrate: look at 9 dots, one after another (about 17 seconds). Keep your head still.")
        line("K     Touch-up: click 5 green dots. Corrects drift after you move in your chair.")
        line("T     Box test: 20 rounds. One of 4 boxes lights up; look at the white dot in it.")
        line("J     Steering test: same boxes, but focus moves with the direction your eyes and head move.")
        line("Y     Harder box test: 3×3 boxes, 18 rounds.")
        line("L     Live view: a ring shows where the app thinks you look. Clicking anywhere corrects drift.")
        line("S     Live steering: 6 windows; turn your eyes and head toward one to move the focus.")
        line("Esc   Stop a step, or quit from this screen.")
        if let s = lastSummary {
            y -= 20
            line(String(format: "Last test (%@, %@): %ld of %ld right (%.0f%%).",
                        s.testType, s.grid, s.correct, s.trials, s.accuracy * 100),
                 color: s.accuracy >= passRate ? .systemGreen : .systemOrange, weight: .semibold)
        }
    }

    private func drawCalibration(point: Int, elapsed: Double) {
        guard point < calPoints.count else { return }
        let p = calPoints[point]
        let shrink = min(1, max(0, elapsed / calSettle))
        let r = CGFloat(30 - 22 * shrink)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
    }

    private func drawGrid(_ l: Layout) {
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        for i in 1..<max(l.cols, 2) where i < l.cols {
            let x = viewW * CGFloat(i) / CGFloat(l.cols)
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: viewH))
        }
        for i in 1..<max(l.rows, 2) where i < l.rows {
            let y = viewH * CGFloat(i) / CGFloat(l.rows)
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: viewW, y: y))
        }
        path.stroke()
    }

    private func drawFocus(_ rect: NSRect) {
        NSColor.systemYellow.setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: 10, dy: 10))
        frame.lineWidth = 5
        frame.stroke()
    }

    private func drawTest(trial: Int) {
        drawGrid(layout)
        guard trial < order.count else { return }
        let rect = layout.rect(order[trial], in: bounds.size)
        NSColor.systemBlue.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: rect.insetBy(dx: 6, dy: 6)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - 10, y: rect.midY - 10, width: 20, height: 20)).fill()
        if testKind == .steer {
            // Glance will show a glow on the chosen window, so the steering test shows it too.
            drawFocus(layout.rect(steering.focus, in: bounds.size))
            let label = trial == 0 ? "Start: look at the lit box" : "Round \(trial) of \(order.count - 1)"
            drawText(label, at: CGPoint(x: 24, y: 24), size: 14, color: .gray)
        } else {
            drawText("Round \(trial + 1) of \(order.count)", at: CGPoint(x: 24, y: 24), size: 14, color: .gray)
        }
    }

    private func drawTouchUp(dot: Int) {
        guard dot < touchUpPoints.count else { return }
        let p = touchUpPoints[dot]
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)).fill()
        drawText("Look at the green dot and click it (\(dot + 1) of \(touchUpPoints.count))",
                 at: CGPoint(x: 24, y: 24), size: 14, color: .gray)
    }

    private func drawResult() {
        guard let s = lastSummary else { return }
        let pct = Int((s.accuracy * 100).rounded())
        let pass = s.accuracy >= passRate
        var y = viewH * 0.65
        drawText("Picked the right box \(s.correct) of \(s.trials) times (\(pct)%)",
                 at: CGPoint(x: viewW / 2, y: y), size: 40, weight: .bold, centered: true)
        y -= 64
        let verdict: String
        if s.grid == "2x2" {
            verdict = pass ? "PASS: 90% or better." : "Below 90%."
        } else {
            verdict = "3×3 is a stretch goal; the 2×2 tests decide."
        }
        drawText(verdict, at: CGPoint(x: viewW / 2, y: y), size: 26,
                 color: pass ? .systemGreen : .systemOrange, weight: .semibold, centered: true)
        y -= 48
        let kind = s.testType == TestKind.steer.rawValue ? "steering" : "box under the gaze"
        drawText(String(format: "%@ test, %@ · single frames right %.0f%% · %@ · %ld drift clicks",
                        kind, s.grid, s.frameAccuracy * 100, s.featureSet, s.clicksUsed),
                 at: CGPoint(x: viewW / 2, y: y), size: 17, color: .lightGray, centered: true)
        y -= 34
        drawText("Saved: \(savedPath)", at: CGPoint(x: viewW / 2, y: y), size: 14, color: .gray, centered: true)
        y -= 50
        drawText("T box test    J steering test    K touch-up    L live    S live steering    C calibrate    Esc menu",
                 at: CGPoint(x: viewW / 2, y: y), size: 16, centered: true)
    }

    private func drawLive() {
        let l = Layout(cols: 2, rows: 2)
        drawGrid(l)
        if let g = gaze {
            let c = l.index(at: g, in: bounds.size)
            if c >= 0 {
                NSColor.systemBlue.withAlphaComponent(0.25).setFill()
                NSBezierPath(rect: l.rect(c, in: bounds.size).insetBy(dx: 6, dy: 6)).fill()
            }
            let r: CGFloat = 16
            NSColor.systemYellow.setStroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: g.x - r, y: g.y - r, width: 2 * r, height: 2 * r))
            dot.lineWidth = 3
            dot.stroke()
        }
        drawText("Live view: look around. Click where you look to correct drift. Esc to go back.",
                 at: CGPoint(x: 24, y: 24), size: 14, color: .gray)
    }

    private func drawSteerLive() {
        let size = bounds.size
        for i in 0..<liveLayout.count {
            let rect = liveLayout.rect(i, in: size).insetBy(dx: 12, dy: 12)
            let focused = i == steering.focus
            NSColor(calibratedWhite: 1, alpha: focused ? 0.16 : 0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            if focused { drawFocus(liveLayout.rect(i, in: size).insetBy(dx: 2, dy: 2)) }
            let name = i < liveNames.count ? liveNames[i] : "Window \(i + 1)"
            drawText(name, at: CGPoint(x: rect.minX + 20, y: rect.maxY - 40), size: 22,
                     color: focused ? .white : .gray, weight: focused ? .semibold : .regular)
        }
        if let s = steerPoint {
            NSColor(calibratedWhite: 1, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12)).fill()
        }
        drawText("Live steering: turn your eyes and head toward a window; keep turning to keep moving. Esc to go back.",
                 at: CGPoint(x: 24, y: 24), size: 14, color: .gray)
    }

    private func drawText(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor = .white,
                          weight: NSFont.Weight = .regular, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let text = NSAttributedString(string: s, attributes: attributes)
        var origin = p
        if centered { origin.x -= text.size().width / 2 }
        text.draw(at: origin)
    }
}
