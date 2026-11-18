import AppKit
import CoreGraphics
import Foundation

/// One open Mac window as the Quest headset needs to know it: a stable id for its lifetime, which app it belongs
/// to, and where it sits on the main display. Pure value type so roster diffing and capping are testable without
/// a window server.
struct QuestWindowInfo: Equatable {
    let id: UInt32
    let pid: pid_t
    let app: String
    let title: String
    let bounds: CGRect
    /// Front-to-back order on the Mac (0 is frontmost). Panels lift toward the user in this order.
    let z: Int

    var json: [String: Any] {
        ["id": Int(id), "app": app, "title": title,
         "w": Int(bounds.width), "h": Int(bounds.height), "z": z,
         "bx": Int(bounds.minX), "by": Int(bounds.minY),
         "bw": Int(bounds.width), "bh": Int(bounds.height)]
    }
}

/// Roster bookkeeping that does not need a display: what changed, and how many windows fit on the headset.
enum WindowRoster {
    static let maxPanels = 8

    /// Kept windows (at most `maxPanels`, frontmost first) plus how many were left out.
    static func cap(_ windows: [QuestWindowInfo], maxPanels: Int = maxPanels) -> (kept: [QuestWindowInfo], more: Int) {
        let sorted = windows.sorted { $0.z < $1.z }
        return (Array(sorted.prefix(maxPanels)), max(0, sorted.count - maxPanels))
    }

    static func changed(old: [QuestWindowInfo], new: [QuestWindowInfo]) -> Bool {
        old != new
    }

    static func removedIDs(old: [QuestWindowInfo], new: [QuestWindowInfo]) -> [UInt32] {
        let newIDs = Set(new.map(\.id))
        return old.map(\.id).filter { !newIDs.contains($0) }
    }
}

/// The live list of open windows, refreshed from the window server. Reuses the same filters as
/// `WindowLocator.windowUnderPointer` (layer 0, on screen, at least 80x60, not Glance itself) so a panel the
/// headset shows is always a window Glance could already talk to.
final class WindowRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [QuestWindowInfo] = []
    private var targets: [UInt32: TargetWindow] = [:]
    private(set) var moreCount = 0

    /// Refresh from CGWindowList. Returns true when the capped roster changed and the headset needs a new one.
    @discardableResult
    func refresh() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [QuestWindowInfo] = []
        var foundTargets: [UInt32: TargetWindow] = [:]
        for (index, info) in list.enumerated() {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(pidNumber) != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let number = info[kCGWindowNumber as String] as? Int
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            if bounds.width < 80 || bounds.height < 60 { continue }
            let pid = pid_t(pidNumber)
            let app = NSRunningApplication(processIdentifier: pid)
            let name = (info[kCGWindowOwnerName as String] as? String) ?? app?.localizedName ?? "Unknown app"
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let id = UInt32(number)
            found.append(QuestWindowInfo(id: id, pid: pid, app: name, title: title, bounds: bounds, z: index))
            foundTargets[id] = TargetWindow(windowID: CGWindowID(number), pid: pid, appName: name,
                                            bundleID: app?.bundleIdentifier ?? "", title: title, bounds: bounds)
        }
        let capped = WindowRoster.cap(found)
        let keptIDs = Set(capped.kept.map(\.id))
        lock.lock()
        let didChange = WindowRoster.changed(old: windows, new: capped.kept) || moreCount != capped.more
        windows = capped.kept
        targets = foundTargets.filter { keptIDs.contains($0.key) }   // no aiming at windows with no panel
        moreCount = capped.more
        lock.unlock()
        return didChange
    }

    func snapshot() -> [QuestWindowInfo] {
        lock.lock(); defer { lock.unlock() }
        return windows
    }

    func target(for id: UInt32) -> TargetWindow? {
        lock.lock(); defer { lock.unlock() }
        return targets[id]
    }

    var rosterJSON: [String: Any] {
        lock.lock()
        let wins = windows
        let more = moreCount
        lock.unlock()
        let display = CGDisplayBounds(CGMainDisplayID())
        return ["type": "windows", "windows": wins.map(\.json), "more": more,
                "display": ["w": Int(display.width), "h": Int(display.height)]]
    }
}
