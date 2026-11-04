import CoreGraphics
import Foundation

/// A grid of windows on the screen. Box 0 is the top-left, then row by row.
struct Layout: Equatable {
    let cols: Int
    let rows: Int

    var count: Int { cols * rows }
    var name: String { "\(cols)x\(rows)" }

    /// Box rectangle in view coordinates (origin bottom-left).
    func rect(_ index: Int, in size: CGSize) -> CGRect {
        let col = index % cols
        let rowFromTop = index / cols
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        return CGRect(x: CGFloat(col) * cw, y: size.height - CGFloat(rowFromTop + 1) * ch, width: cw, height: ch)
    }

    /// Box under a point. -1 if the point is not a number.
    func index(at p: CGPoint, in size: CGSize) -> Int {
        let fx = Double(p.x / (size.width / CGFloat(cols)))
        let fy = Double((size.height - p.y) / (size.height / CGFloat(rows)))
        guard fx.isFinite, fy.isFinite else { return -1 }
        let col = Int(min(Double(cols - 1), max(0, fx)))
        let row = Int(min(Double(rows - 1), max(0, fy)))
        return row * cols + col
    }
}

/// Moves focus between windows by the DIRECTION of gaze shifts, not by where the gaze point is.
///
/// The gaze estimate already mixes eye and head features, so:
/// - eyes and head turn right together (a real shift of attention) → the estimate jumps right → focus steps right;
/// - keep turning and it keeps stepping, one window per step, until you stop;
/// - head moves but the eyes stay on the same spot → the two cancel → focus stays;
/// - slow drift and a calibration offset move the estimate slowly → focus stays.
/// At the edge of the layout a step is clamped, so in a 2-column layout "move right" always means the right column.
final class Steering {
    var layout: Layout
    var jumpX = 0.18          // shift needed, as a fraction of the screen width
    var jumpY = 0.22          // ... of the screen height (up/down is noisier)
    var window = 0.25         // seconds over which a shift is measured
    var cooldown = 0.35       // seconds between steps
    var snapAfter: Double?    // if set: also snap to the box where the gaze has rested this long

    private(set) var focus = 0
    private var history: [(t: Double, p: CGPoint)] = []
    private var lastStep = -10.0
    private var restBox = -1
    private var restSince = 0.0

    init(layout: Layout) {
        self.layout = layout
    }

    func reset(focus: Int) {
        self.focus = focus
        history = []
        lastStep = -10
        restBox = -1
    }

    /// Feed one gaze estimate (view coordinates). Returns true when the focus moved.
    @discardableResult
    func update(_ p: CGPoint, t: Double, size: CGSize) -> Bool {
        history.append((t: t, p: p))
        while let first = history.first, t - first.t > 1.0 { history.removeFirst() }

        if let snap = snapAfter {
            let box = layout.index(at: p, in: size)
            if box != restBox {
                restBox = box
                restSince = t
            } else if box >= 0, box != focus, t - restSince >= snap, t - lastStep >= snap {
                focus = box
                lastStep = t
                history = [(t: t, p: p)]
                return true
            }
        }

        guard t - lastStep >= cooldown,
              let past = history.first(where: { t - $0.t <= window }) else { return false }
        let fx = Double((p.x - past.p.x) / size.width)
        let fy = Double((p.y - past.p.y) / size.height)

        var col = focus % layout.cols
        var row = focus / layout.cols
        var moved = false
        if abs(fx) >= jumpX && abs(fx) >= 0.5 * abs(fy) {
            col += fx > 0 ? 1 : -1
            moved = true
        }
        if abs(fy) >= jumpY && abs(fy) >= 0.5 * abs(fx) {
            row += fy > 0 ? -1 : 1     // view y points up; row 0 is the top
            moved = true
        }
        guard moved else { return false }

        col = min(layout.cols - 1, max(0, col))
        row = min(layout.rows - 1, max(0, row))
        lastStep = t
        history = [(t: t, p: p)]      // measure the next step from here
        let next = row * layout.cols + col
        guard next != focus else { return false }
        focus = next
        return true
    }
}
