import AppKit
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.connection == .unpaired {
                pairingSection
            } else {
                monitorControls
                    .disabled(!model.canControl)
                    .opacity(model.canControl ? 1 : 0.45)
            }

            if model.nightShiftAvailable {
                Divider()
                nightShiftSection
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task { await model.panelOpened() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tv")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.monitorName)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var monitorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LevelRow(
                title: "Volume",
                symbol: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                valueText: model.muted ? "Muted" : "\(model.volume)",
                value: model.volume,
                range: 0...100,
                symbolHelp: model.muted ? "Unmute" : "Mute",
                onSymbolTap: { model.setMuted(!model.muted) },
                onChange: model.setVolume
            )
            LevelRow(
                title: "Brightness",
                symbol: "sun.max.fill",
                valueText: "\(model.backlight)",
                value: model.backlight,
                range: 0...50,
                symbolHelp: nil,
                onSymbolTap: nil,
                onChange: model.setBacklight
            )
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Colour tone")
                Picker("Colour tone", selection: Binding(get: { model.colorTone }, set: model.setColorTone)) {
                    Text("Cool").tag("Cool")
                    Text("Standard").tag("Standard")
                    Text("Warm 1").tag("Warm1")
                    Text("Warm 2").tag("Warm2")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.pairingNote
                ?? "This Mac is not paired with the monitor yet. Turn on IP Remote in the monitor's network expert settings, then pair.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.pair() }
            } label: {
                if model.isPairing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the monitor…")
                    }
                } else {
                    Text("Pair with monitor")
                }
            }
            .disabled(model.isPairing)
        }
    }

    private var nightShiftSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "moon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(model.nightShiftOn ? .orange : .secondary)
                    .frame(width: 20)
                Text("Night Shift")
                    .font(.system(size: 13))
                Spacer()
                Toggle("Night Shift", isOn: Binding(get: { model.nightShiftOn }, set: model.setNightShift))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            HStack(spacing: 10) {
                Text("Less warm")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.nightShiftStrength }, set: model.setNightShiftStrength), in: 0...1)
                    .controlSize(.small)
                Text("More warm")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.nightShiftOn)
            .opacity(model.nightShiftOn ? 1 : 0.45)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Volume and brightness keys")
                    .font(.system(size: 12))
                Spacer()
                if model.keysActive {
                    Text("On")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Allow in Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                Text("Open at login")
                    .font(.system(size: 12))
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Status

    private var statusText: String {
        switch model.connection {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unpaired: return "Not paired"
        case .unreachable: return "Monitor not reachable"
        }
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .secondary
        case .unpaired, .unreachable: return .orange
        }
    }
}

private struct SectionLabel: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

/// A labelled slider with an icon and the monitor's own number for the level.
private struct LevelRow: View {
    let title: String
    let symbol: String
    let valueText: String
    let value: Int
    let range: ClosedRange<Int>
    let symbolHelp: String?
    let onSymbolTap: (() -> Void)?
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(title)
                Spacer()
                Text(valueText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                icon
                Slider(
                    value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                )
            }
        }
    }

    @ViewBuilder private var icon: some View {
        let image = Image(systemName: symbol)
            .font(.system(size: 13))
            .frame(width: 20, height: 20)
        if let onSymbolTap {
            Button(action: onSymbolTap) { image }
                .buttonStyle(.plain)
                .help(symbolHelp ?? "")
                .accessibilityLabel(symbolHelp ?? title)
        } else {
            image.foregroundStyle(.secondary)
        }
    }
}
