import AppKit
import CoreAudio

/// Decides whether a key press is meant for the monitor or should be left to macOS.
enum Routing {
    private static let samsungVendorID: UInt32 = 0x4C2D

    /// The Samsung display, if one is connected.
    static func monitorScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayVendorNumber(id) == samsungVendorID
        }
    }

    /// Brightness keys follow the pointer: they act on the monitor only while the pointer is on it,
    /// so the MacBook's own display keeps its brightness keys when the lid is open.
    static func brightnessKeysTargetMonitor() -> Bool {
        guard let monitor = monitorScreen() else { return false }
        if NSScreen.screens.count == 1 { return true }
        return NSMouseInRect(NSEvent.mouseLocation, monitor.frame, false)
    }

    /// Volume keys act on the monitor only while sound is going out over the display cable.
    /// With headphones or the Mac's speakers selected, macOS keeps handling them.
    static func volumeKeysTargetMonitor() -> Bool {
        guard monitorScreen() != nil else { return false }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
    }
}
