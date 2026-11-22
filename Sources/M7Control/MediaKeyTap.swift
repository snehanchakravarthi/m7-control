import AppKit
import M7Core

/// Listens for the keyboard's volume and brightness keys before macOS acts on them.
/// Needs Accessibility permission; `start()` returns false until it is granted.
final class MediaKeyTap {
    /// Called on the main thread for every volume or brightness key event.
    /// Return true to keep the event from reaching macOS.
    var handler: (MediaKeyEvent, _ fineStep: Bool) -> Bool = { _, _ in false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private static let systemDefinedType: UInt32 = 14
    private static let specialKeySubtype: Int16 = 8

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue()
            return owner.process(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            // Special-key events (Apple keyboards) plus ordinary key events, because some
            // keyboards send brightness as F14/F15.
            eventsOfInterest: (CGEventMask(1) << CGEventMask(MediaKeyTap.systemDefinedType))
                | (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
                | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue)),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
        return true
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if it ever responds slowly; switch it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        // Shift+Option asks for a finer step, as it does for the Mac's own volume and brightness.
        let fine = flags.contains(.maskShift) && flags.contains(.maskAlternate)

        if type == .keyDown || type == .keyUp {
            // Every ordinary key press passes through here, so this path does the minimum:
            // one key-code lookup, and anything that is not a brightness key goes straight on.
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let key = MediaKeyDecoder.brightnessKey(forKeyCode: keyCode),
                  !flags.contains(.maskCommand), !flags.contains(.maskControl)
            else { return Unmanaged.passUnretained(event) }
            let decoded = MediaKeyEvent(
                key: key,
                isDown: type == .keyDown,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
            return handler(decoded, fine) ? nil : Unmanaged.passUnretained(event)
        }

        guard type.rawValue == MediaKeyTap.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == MediaKeyTap.specialKeySubtype,
              let decoded = MediaKeyDecoder.decode(data1: nsEvent.data1)
        else { return Unmanaged.passUnretained(event) }

        return handler(decoded, fine) ? nil : Unmanaged.passUnretained(event)
    }
}
