import AppKit
import CoreGraphics

/// Which key you hold to talk. Modifier keys are used because they type nothing on their own.
enum TalkKeyChoice: String, CaseIterable {
    case leftOption = "left-option"
    case rightOption = "right-option"
    case rightCommand = "right-command"
    case rightControl = "right-control"
    case fn = "fn"

    var keyCode: Int64 {
        switch self {
        case .leftOption: return 58
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .leftOption, .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }

    var label: String {
        switch self {
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "fn (🌐)"
        }
    }

    /// `--talk-key right-option` on the command line; Left Option by default.
    static func fromArguments() -> TalkKeyChoice {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--talk-key"), i + 1 < args.count,
           let choice = TalkKeyChoice(rawValue: args[i + 1].lowercased()) {
            return choice
        }
        return .leftOption
    }
}

/// Watches one key anywhere on the Mac (a listen-only event tap on its own thread) and reports press and release.
final class TalkKey {
    private let choice: TalkKeyChoice
    private var onDown: (() -> Void)?
    private var onUp: (() -> Void)?
    private var isDown = false
    private var tap: CFMachPort?
    private let queue = DispatchQueue(label: "glance.talkkey")

    init(_ choice: TalkKeyChoice) {
        self.choice = choice
    }

    /// Returns false when macOS does not allow watching keys (Input Monitoring is off for the terminal app).
    func start(onDown: @escaping () -> Void, onUp: @escaping () -> Void) -> Bool {
        self.onDown = onDown
        self.onUp = onUp
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }

        let mask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon = refcon {
                Unmanaged<TalkKey>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: callback, userInfo: me)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: mask, callback: callback, userInfo: me)
        guard let tap = created else { return false }
        self.tap = tap

        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "glance.talkkey"
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == choice.keyCode else { return }
        let down = event.flags.contains(choice.flag)
        if down && !isDown {
            isDown = true
            queue.async { self.onDown?() }
        } else if !down && isDown {
            isDown = false
            queue.async { self.onUp?() }
        }
    }
}

/// Esc anywhere ends a hands-free session. Key presses are watched only while a session is on, and then only to see
/// whether one was Esc: nothing is kept, and every key goes through untouched. Main thread.
final class EscapeKey {
    private static let escape: Int64 = 53
    private let onEscape: () -> Void
    private let queue = DispatchQueue(label: "glance.escape")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    /// Returns false when macOS does not allow watching keys (Input Monitoring is off for the terminal app).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon = refcon {
                Unmanaged<EscapeKey>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue),
                                          callback: callback, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == EscapeKey.escape {
            queue.async { self.onEscape() }
        }
    }
}
