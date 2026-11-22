import AppKit
import ApplicationServices
import M7Core
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        // Command-line checks that need no window and no Accessibility permission.
        if arguments.contains("--status") || arguments.contains("--nudge") {
            Task { @MainActor in
                await CommandLineCheck.run(nudge: arguments.contains("--nudge"))
                exit(0)
            }
            dispatchMain()
        }
        if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
            Task { @MainActor in
                await CommandLineCheck.snapshotPanel(to: arguments[flag + 1])
                exit(0)
            }
            NSApplication.shared.run()
        }
        M7ControlApp.main()
    }
}

struct M7ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(appDelegate.model)
        } label: {
            Image(systemName: "tv")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()

    private let hud = HUDController()
    private let keyTap = MediaKeyTap()
    private var accessibilityTimer: Timer?
    private var reconnectTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onFeedback = { [hud] feedback in hud.show(feedback) }

        keyTap.handler = { [weak self] event, fine in
            MainActor.assumeIsolated {
                guard let self, self.model.canControl else { return false }
                let forMonitor = event.key.isVolume
                    ? Routing.volumeKeysTargetMonitor()
                    : Routing.brightnessKeysTargetMonitor()
                guard forMonitor else { return false }
                // Key-up events are swallowed too, so macOS never sees half of a press.
                if event.isDown { self.model.handleKey(event.key, fine: fine) }
                return true
            }
        }

        Task { await model.start() }
        enableKeys()
        observeSystemChanges()
    }

    /// Starts the key listener, asking for Accessibility once and then waiting for it to be granted.
    private func enableKeys() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt), keyTap.start() {
            model.keysActive = true
            return
        }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.keyTap.start() else { return }
                self.model.keysActive = true
                self.accessibilityTimer?.invalidate()
                self.accessibilityTimer = nil
            }
        }
    }

    /// The monitor drops off the network when it sleeps, so state is re-read on wake and display
    /// changes, and retried slowly while it is unreachable. Nothing is polled while connected.
    private func observeSystemChanges() {
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh
        )
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: refresh
        )
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.connection == .unreachable || self.model.connection == .connecting else { return }
                Task { await self.model.refresh() }
            }
        }
    }
}

/// `M7Control --status` prints what the app sees; `--nudge` also moves volume and brightness
/// one step and back through the same code path the keys use; `--snapshot file.png` renders
/// the menu bar panel with live values into an image, for checking layout without opening it.
@MainActor
enum CommandLineCheck {
    static func snapshotPanel(to path: String) async {
        let model = MonitorModel()
        await model.start()
        model.keysActive = AXIsProcessTrusted()
        let hosting = NSHostingView(
            rootView: PanelView().environmentObject(model).background(Color(nsColor: .windowBackgroundColor))
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        try? await Task.sleep(for: .milliseconds(900))
        hosting.setFrameSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("panel \(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)) written to \(path)")
    }

    static func run(nudge: Bool) async {
        let model = MonitorModel()
        await model.start()
        print("monitor screen:      \(Routing.monitorScreen()?.localizedName ?? "none")")
        print("connection:          \(model.connection)")
        print("volume / muted:      \(model.volume) / \(model.muted)")
        print("backlight:           \(model.backlight)")
        print("colour tone:         \(model.colorTone)")
        print("night shift:         available=\(model.nightShiftAvailable) on=\(model.nightShiftOn) strength=\(String(format: "%.2f", model.nightShiftStrength))")
        print("volume keys -> monitor:     \(Routing.volumeKeysTargetMonitor())")
        print("brightness keys -> monitor: \(Routing.brightnessKeysTargetMonitor())")
        print("accessibility granted:      \(AXIsProcessTrusted())")
        print("bonjour discovery:   \(await Discovery.hosts())")

        guard nudge, model.canControl else { return }
        let steps: [(MediaKey, String)] = [
            (.volumeUp, "volume up"), (.volumeDown, "volume down"),
            (.brightnessDown, "brightness down"), (.brightnessUp, "brightness up"),
        ]
        for (key, name) in steps {
            model.handleKey(key, fine: false)
            try? await Task.sleep(for: .milliseconds(700))
            await model.refresh()
            print("after \(name): volume=\(model.volume) backlight=\(model.backlight)")
        }
    }
}
