import Foundation
import Testing
@testable import Glance

/// Floating windows: roster capping, ordering and change detection (the parts that need no window server).
struct FloatingWindowTests {

    private func win(_ id: UInt32, z: Int, x: CGFloat = 0) -> QuestWindowInfo {
        QuestWindowInfo(id: id, pid: 100, app: "App\(id)", title: "T\(id)",
                        bounds: CGRect(x: x, y: 0, width: 400, height: 300), z: z)
    }

    @Test func rosterCapsAtMaxPanelsFrontmostFirst() {
        let windows = (0..<11).map { win(UInt32($0), z: 10 - $0) } // id 10 is frontmost
        let capped = WindowRoster.cap(windows)
        #expect(capped.kept.count == WindowRoster.maxPanels)
        #expect(capped.more == 3)
        #expect(capped.kept.first?.id == 10)
        #expect(capped.kept.last?.id == 3)
    }

    @Test func rosterUnderCapKeepsEverything() {
        let capped = WindowRoster.cap([win(1, z: 1), win(2, z: 0)])
        #expect(capped.kept.count == 2)
        #expect(capped.more == 0)
        #expect(capped.kept.first?.id == 2)
    }

    @Test func rosterChangeDetection() {
        let a = [win(1, z: 0), win(2, z: 1)]
        #expect(!WindowRoster.changed(old: a, new: a))
        #expect(WindowRoster.changed(old: a, new: [win(1, z: 0)]))
        #expect(WindowRoster.changed(old: a, new: [win(1, z: 0, x: 50), win(2, z: 1)])) // moved
    }

    @Test func removedIDsFindsClosedWindows() {
        let old = [win(1, z: 0), win(2, z: 1), win(3, z: 2)]
        #expect(WindowRoster.removedIDs(old: old, new: [win(2, z: 0)]) == [1, 3])
        #expect(WindowRoster.removedIDs(old: old, new: old).isEmpty)
    }
}
