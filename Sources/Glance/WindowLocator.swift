import AppKit
import CoreGraphics

/// A window on screen, as the window server reports it.
struct TargetWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String
    var title: String
    /// Global coordinates, origin at the top-left of the main display (the same space AppleScript `bounds` use).
    let bounds: CGRect
}

enum WindowLocator {
    /// Mouse position in global CoreGraphics coordinates (origin top-left).
    static func pointer() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The top-most normal window under the mouse pointer.
    static func windowUnderPointer() -> TargetWindow? {
        let point = pointer()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for info in list {   // the list is ordered front to back
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(pidNumber) != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point),
                  let number = info[kCGWindowNumber as String] as? Int
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            if bounds.width < 80 || bounds.height < 60 { continue }   // skip tiny helper windows

            let pid = pid_t(pidNumber)
            let app = NSRunningApplication(processIdentifier: pid)
            let name = (info[kCGWindowOwnerName as String] as? String) ?? app?.localizedName ?? "Unknown app"
            // Window titles need Screen Recording permission here; the adapters read them another way if empty.
            let title = (info[kCGWindowName as String] as? String) ?? ""
            return TargetWindow(windowID: CGWindowID(number), pid: pid, appName: name,
                                bundleID: app?.bundleIdentifier ?? "", title: title, bounds: bounds)
        }
        return nil
    }
}
