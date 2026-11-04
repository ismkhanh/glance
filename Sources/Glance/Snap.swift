import AppKit
import ApplicationServices
import CoreText

/// Every clickable element in a window (buttons, links, fields, tabs…) with its frame on screen,
/// read in one walk of the window's accessibility tree. Run it on a background queue.
enum Clickables {
    private static let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
                                kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]

    static func collect(in window: TargetWindow, limit: Int = 400, budget: Int = 4000, seconds: Double = 1.2) -> [PointedElement] {
        guard let root = AX.window(for: window) else { return [] }
        let start = Date()
        let visible = window.bounds.insetBy(dx: -2, dy: -2)
        let maxArea = 0.6 * window.bounds.width * window.bounds.height
        let attributes = names as CFArray
        var found: [PointedElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count && head < budget && found.count < limit {
            if Date().timeIntervalSince(start) > seconds { break }
            let (el, depth) = queue[head]
            head += 1
            _ = AXUIElementSetMessagingTimeout(el, 0.15)
            // One round trip per element for all eight attributes (much faster than eight calls).
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attributes, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == names.count else { continue }

            let role = (values[0] as? String) ?? ""
            let frame = rect(values[1], values[2])
            // A branch that is scrolled out of the window cannot be pointed at: skip all of it.
            if let f = frame, f.width > 0, f.height > 0, !f.intersects(visible) { continue }

            if UITree.actionable.contains(role), let f = frame, f.width >= 4, f.height >= 4, f.width * f.height <= maxArea {
                let label = text(values[4]) ?? text(values[5]) ?? text(values[6]).map { String($0.prefix(160)) }
                    ?? text(values[7]) ?? ""
                _ = AXUIElementSetMessagingTimeout(el, 0)   // pressing it later may take longer than a quick read
                found.append(PointedElement(role: role, label: label, frame: f, element: el))
            }
            if depth < 40, let kids = values[3] as? [AXUIElement] {
                for kid in kids { queue.append((kid, depth + 1)) }
            }
        }
        return found
    }

    private static func text(_ value: AnyObject) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func rect(_ position: AnyObject, _ size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else {
            return nil
        }
        return CGRect(origin: p, size: s)
    }
}

/// The "snap" step: what the pointer most likely means, and the numbered choices around it.
enum Snap {
    static let reach: CGFloat = 40          // pt: snap to a clickable this close to the pointer
    static let reachOnText: CGFloat = 12    // pt: when the pointer is on text or an image, snap only if very close
    static let nearbyReach: CGFloat = 100   // pt: clickables this close get a number
    static let maxNearby = 5

    /// 0 when the point is inside the rect, else the distance to its nearest edge.
    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    private static func key(_ p: CGPoint, _ r: CGRect) -> (CGFloat, CGFloat) {
        (distance(p, r), hypot(p.x - r.midX, p.y - r.midY))
    }

    /// The clickable the pointer is on; else the nearest clickable within reach; else the text or image under it.
    static func choose(at p: CGPoint, probe: PointedElement?, clickables: [PointedElement]) -> PointedElement? {
        if let e = probe, e.isActionable, distance(p, e.frame) == 0 { return e }
        let onContent = probe.map { distance(p, $0.frame) == 0 } ?? false
        let limit = onContent ? reachOnText : reach
        var best: PointedElement?
        var bestKey = (CGFloat.infinity, CGFloat.infinity)
        for c in clickables {
            let k = key(p, c.frame)
            if k.0 <= limit && k < bestKey {
                best = c
                bestKey = k
            }
        }
        if var b = best {
            b.snapped = bestKey.0 > 0
            return b
        }
        return probe.flatMap { distance(p, $0.frame) == 0 ? $0 : nil }
    }

    /// Clickables near the pointer, nearest first. The highlighted one, when it is clickable, is number 1.
    static func nearby(at p: CGPoint, chosen: PointedElement?, clickables: [PointedElement]) -> [PointedElement] {
        var list = clickables.filter { distance(p, $0.frame) <= nearbyReach }
            .sorted { key(p, $0.frame) < key(p, $1.frame) }
        if let c = chosen, c.isActionable {
            list.removeAll { PointedElement.same($0, c) }
            list.insert(c, at: 0)
        }
        return Array(list.prefix(maxNearby))
    }

    /// "about 40 pt right and above", from the highlighted element to another one.
    static func direction(from a: CGRect, to b: CGRect) -> String {
        let dx = b.midX - a.midX
        let dy = b.midY - a.midY          // screen y grows downwards
        var parts: [String] = []
        if abs(dx) > 8 { parts.append(dx > 0 ? "right" : "left") }
        if abs(dy) > 8 { parts.append(dy > 0 ? "below" : "above") }
        if parts.isEmpty { return "same place" }
        return "about \(Int(hypot(dx, dy).rounded())) pt \(parts.joined(separator: " and "))"
    }
}

/// Presses an element: through accessibility first; if the app refuses, a real click on its middle.
enum Clicker {
    static func press(_ e: PointedElement, in target: TargetWindow) -> String {
        if AX.press(e.element) { return "Pressed \(e.summary)." }
        let middle = CGPoint(x: e.frame.midX, y: e.frame.midY)
        return click(at: middle, in: target) ? "Clicked \(e.summary)." : "Could not press \(e.summary)."
    }

    /// Moves the pointer only for the click itself, then puts it back where your head (or mouse) left it.
    static func click(at point: CGPoint, in target: TargetWindow) -> Bool {
        let back = WindowLocator.pointer()
        AX.raise(target, window: AX.window(for: target))
        usleep(150_000)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        CGWarpMouseCursorPosition(point)
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        usleep(80_000)
        CGWarpMouseCursorPosition(back)
        return true
    }
}

/// A small picture of the area around the pointer, with the numbered elements boxed, so Muse can follow
/// "the blue one" or "the icon on the left". Only this crop is sent, never the whole screen.
@available(macOS 14.0, *)
enum NearbyPicture {
    static func jpeg(window: TargetWindow, nearby: [PointedElement]) async throws -> Data {
        let full = try await WindowCapture.image(windowID: window.windowID, maxWidth: 4000)
        let wb = window.bounds
        let scale = CGFloat(full.width) / max(wb.width, 1)

        // The area: all numbered elements plus a margin, at least 260 pt square, inside the window.
        var area = nearby.map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -40)
        if area.width < 260 { area = area.insetBy(dx: -(260 - area.width) / 2, dy: 0) }
        if area.height < 260 { area = area.insetBy(dx: 0, dy: -(260 - area.height) / 2) }
        area = area.intersection(wb)
        guard !area.isNull, area.width > 10, area.height > 10 else { throw ScriptError(message: "Nothing to show near the pointer.") }

        let pixels = CGRect(x: (area.minX - wb.minX) * scale, y: (area.minY - wb.minY) * scale,
                            width: area.width * scale, height: area.height * scale).integral
        guard let crop = full.cropping(to: pixels) else { throw ScriptError(message: "Could not cut the picture.") }
        let w = crop.width
        let h = crop.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScriptError(message: "Could not draw the picture.")
        }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))

        let mark = CGColor(red: 1, green: 0.2, blue: 0.6, alpha: 1)    // pink stands out on most UIs
        let badge = 13 * scale
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 13 * scale, nil)
        for (i, e) in nearby.enumerated() {
            // Window points → crop pixels, with y flipped (the bitmap's origin is bottom-left).
            let r = CGRect(x: (e.frame.minX - area.minX) * scale, y: CGFloat(h) - (e.frame.maxY - area.minY) * scale,
                           width: e.frame.width * scale, height: e.frame.height * scale)
            ctx.setStrokeColor(mark)
            ctx.setLineWidth(max(2, 1.5 * scale))
            ctx.stroke(r.insetBy(dx: -2, dy: -2))

            let centre = CGPoint(x: max(badge, r.minX - badge * 0.2), y: min(CGFloat(h) - badge, r.maxY + badge * 0.2))
            ctx.setFillColor(mark)
            ctx.fillEllipse(in: CGRect(x: centre.x - badge, y: centre.y - badge, width: badge * 2, height: badge * 2))

            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(i + 1)", attributes: attributes) as CFAttributedString)
            let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.textPosition = CGPoint(x: centre.x - b.width / 2 - b.minX, y: centre.y - b.height / 2 - b.minY)
            CTLineDraw(line, ctx)
        }
        guard let marked = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: marked).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { throw ScriptError(message: "Could not encode the picture.") }
        return data
    }
}
