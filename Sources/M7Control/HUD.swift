import AppKit
import SwiftUI

/// What the on-screen indicator should show after a key press.
enum HUDFeedback: Equatable {
    case volume(level: Int, muted: Bool)
    case brightness(level: Int)

    var symbol: String {
        switch self {
        case let .volume(level, muted):
            if muted || level == 0 { return "speaker.slash.fill" }
            if level < 34 { return "speaker.wave.1.fill" }
            if level < 67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return "sun.max.fill"
        }
    }

    var fraction: Double {
        switch self {
        case let .volume(level, muted): return muted ? 0 : Double(level) / 100
        case let .brightness(level): return Double(level) / 50
        }
    }

    /// The number shown is the monitor's own scale, so it matches the monitor's menus.
    var label: String {
        switch self {
        case let .volume(level, muted): return muted ? "Mute" : String(level)
        case let .brightness(level): return String(level)
        }
    }
}

private final class HUDState: ObservableObject {
    @Published var feedback: HUDFeedback = .volume(level: 0, muted: false)
}

private struct HUDView: View {
    @ObservedObject var state: HUDState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.feedback.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24, alignment: .center)
                .contentTransition(.symbolEffect(.replace))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.16))
                    Capsule()
                        .fill(.primary.opacity(0.9))
                        .frame(width: max(0, proxy.size.width * state.feedback.fraction))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.12), value: state.feedback.fraction)

            Text(state.feedback.label)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .frame(width: HUDController.size.width, height: HUDController.size.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// A small pill near the top-right of the monitor, where macOS shows its own volume indicator.
@MainActor
final class HUDController {
    static let size = CGSize(width: 268, height: 46)

    private let state = HUDState()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ feedback: HUDFeedback) {
        state.feedback = feedback
        let panel = panel ?? makePanel()
        self.panel = panel

        let screen = Routing.monitorScreen() ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = CGPoint(
                x: visible.maxX - HUDController.size.width - 16,
                y: visible.maxY - HUDController.size.height - 12
            )
            panel.setFrame(CGRect(origin: origin, size: HUDController.size), display: true)
        }

        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated {
                if panel?.alphaValue == 0 { panel?.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: HUDController.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: HUDView(state: state))
        return panel
    }
}
