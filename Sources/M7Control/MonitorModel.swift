import AppKit
import Foundation
import M7Core
import NightShiftBridge
import ServiceManagement

/// Sends only the newest value. While one request is in flight, later values replace each other,
/// so dragging a slider or holding a key never builds a backlog of stale commands.
@MainActor
final class LatestSender<Value> {
    private var pending: Value?
    private var busy = false
    private let send: (Value) async -> Void

    init(_ send: @escaping (Value) async -> Void) {
        self.send = send
    }

    func submit(_ value: Value) {
        pending = value
        pump()
    }

    private func pump() {
        guard !busy, let value = pending else { return }
        pending = nil
        busy = true
        Task {
            await send(value)
            busy = false
            pump()
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    enum Connection: Equatable {
        case connecting
        case connected
        /// No token, or the monitor no longer accepts it.
        case unpaired
        /// Paired, but the monitor is off, asleep or not on the network.
        case unreachable
    }

    static let colorTones = ["Cool", "Standard", "Warm1", "Warm2"]

    @Published private(set) var connection: Connection = .connecting
    @Published private(set) var volume = 0
    @Published private(set) var muted = false
    @Published private(set) var backlight = 0
    @Published private(set) var colorTone = ""
    @Published private(set) var nightShiftAvailable = false
    @Published private(set) var nightShiftOn = false
    @Published private(set) var nightShiftStrength = 0.5
    @Published private(set) var isPairing = false
    @Published private(set) var pairingNote: String?
    @Published private(set) var launchAtLogin = false
    /// True once Accessibility is granted and the key listener is running.
    @Published var keysActive = false

    /// Called after a key press changed something, so the on-screen indicator can show it.
    var onFeedback: ((HUDFeedback) -> Void)?

    var monitorName: String { Routing.monitorScreen()?.localizedName ?? "Samsung monitor" }
    var canControl: Bool { connection == .connected }

    private let client = MonitorClient()
    private var pairing: Pairing?
    private var lastSync = Date.distantPast
    private var lastLocate = Date.distantPast
    private var refreshTask: Task<Void, Never>?

    /// The monitor can be changed with its own remote, so cached values are re-read after this long.
    private let staleAfter: TimeInterval = 8
    private let volumeStep = 1
    private let backlightStep = 2

    private lazy var volumeSender = LatestSender<Int> { [weak self] value in
        _ = await self?.send("directVolumeControl", [("volume", .int(value))])
    }

    private lazy var backlightSender = LatestSender<Int> { [weak self] value in
        _ = await self?.send("backlightControl", [("backlight", .int(value))])
    }

    // MARK: Lifecycle

    func start() async {
        pairing = PairingStore.load()
        readNightShift()
        readLaunchAtLogin()
        await refresh()
    }

    func panelOpened() async {
        readNightShift()
        readLaunchAtLogin()
        await refresh()
    }

    /// Re-reads the monitor's state. Concurrent callers share one round of requests.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let current = pairing else {
            connection = .unpaired
            return
        }
        client.pinnedFingerprint = current.fingerprint
        if current.host == nil, await !locate() {
            connection = .unreachable
            return
        }

        var states = await send("getTVStates")
        if states == nil, connection == .unreachable, await locate() {
            states = await send("getTVStates")
        }
        guard let states else { return }

        if let value = states["volume"]?.intValue { volume = value }
        muted = states["mute"]?.stringValue == "muteOn"
        if let value = await send("backlightControl")?["backlight"]?.intValue { backlight = value }
        if let value = await send("colorToneControl")?["colorTone"]?.stringValue { colorTone = value }
        lastSync = Date()
    }

    // MARK: Requests

    @discardableResult
    private func send(_ method: String, _ params: [(String, JSONValue)] = []) async -> [String: JSONValue]? {
        guard let current = pairing, let host = current.host else { return nil }
        do {
            let result = try await client.call(method, params: params, host: host, token: current.token)
            connection = .connected
            if !params.isEmpty { lastSync = Date() }
            return result
        } catch MonitorError.unauthorized {
            connection = .unpaired
        } catch MonitorError.server, MonitorError.malformed {
            // The monitor answered but refused this one command (for example a value out of range).
        } catch {
            connection = .unreachable
        }
        return nil
    }

    /// Looks for the paired monitor at a new address. The certificate pin makes sure the token is
    /// only ever offered to the same device it was issued by.
    private func locate() async -> Bool {
        guard let current = pairing, Date().timeIntervalSince(lastLocate) > 20 else { return false }
        lastLocate = Date()
        for host in await Discovery.hosts() where host != current.host {
            guard (try? await client.call("getTVStates", host: host, token: current.token)) != nil else { continue }
            pairing?.host = host
            if let pairing { try? PairingStore.save(pairing) }
            return true
        }
        return false
    }

    // MARK: Pairing

    func pair() async {
        guard !isPairing else { return }
        isPairing = true
        pairingNote = "Choose Allow on the monitor. The Mac's picture must be showing, not the Samsung home screen."
        defer { isPairing = false }

        var hosts = [pairing?.host].compactMap { $0 }
        for host in await Discovery.hosts() where !hosts.contains(host) { hosts.append(host) }
        guard !hosts.isEmpty else {
            pairingNote = "No Samsung display found on this network. Check that IP Remote is on in the monitor's network settings."
            return
        }

        client.pinnedFingerprint = nil
        for host in hosts {
            do {
                // The prompt on the monitor stays up for about a minute.
                let result = try await client.call("createAccessToken", host: host, token: nil, timeout: 75)
                guard let token = result["AccessToken"]?.stringValue, let fingerprint = client.seenFingerprint else { continue }
                let paired = Pairing(host: host, token: token, fingerprint: fingerprint)
                try? PairingStore.save(paired)
                pairing = paired
                pairingNote = nil
                await refresh()
                return
            } catch MonitorError.unreachable {
                continue
            } catch {
                break
            }
        }
        client.pinnedFingerprint = pairing?.fingerprint
        pairingNote = "Pairing was not approved. Turn on IP Remote in the monitor's network expert settings, then try again."
    }

    // MARK: Controls

    func setVolume(_ value: Int) {
        let clamped = Level.stepped(value, by: 0, in: Level.volumeRange)
        guard clamped != volume || muted else { return }
        volume = clamped
        if muted { setMuted(false) }
        volumeSender.submit(clamped)
    }

    func setMuted(_ value: Bool) {
        muted = value
        Task { await send("muteControl", [("mute", .string(value ? "muteOn" : "muteOff"))]) }
    }

    func setBacklight(_ value: Int) {
        let clamped = Level.stepped(value, by: 0, in: Level.backlightRange)
        guard clamped != backlight else { return }
        backlight = clamped
        backlightSender.submit(clamped)
    }

    func setColorTone(_ tone: String) {
        guard MonitorModel.colorTones.contains(tone), tone != colorTone else { return }
        colorTone = tone
        Task { await send("colorToneControl", [("colorTone", .string(tone))]) }
    }

    /// Applies one press of a volume or brightness key.
    func handleKey(_ key: MediaKey, fine: Bool) {
        Task {
            if Date().timeIntervalSince(lastSync) > staleAfter { await refresh() }
            guard connection == .connected else { return }
            switch key {
            case .volumeUp, .volumeDown:
                let delta = key == .volumeUp ? volumeStep : -volumeStep
                setVolume(Level.stepped(volume, by: delta, in: Level.volumeRange))
                onFeedback?(.volume(level: volume, muted: muted))
            case .mute:
                setMuted(!muted)
                onFeedback?(.volume(level: volume, muted: muted))
            case .brightnessUp, .brightnessDown:
                let step = fine ? 1 : backlightStep
                let delta = key == .brightnessUp ? step : -step
                setBacklight(Level.stepped(backlight, by: delta, in: Level.backlightRange))
                onFeedback?(.brightness(level: backlight))
            }
        }
    }

    // MARK: Night Shift (macOS side)

    func readNightShift() {
        var enabled = false
        var strength: Float = 0
        nightShiftAvailable = M7NightShiftRead(&enabled, &strength)
        guard nightShiftAvailable else { return }
        nightShiftOn = enabled
        nightShiftStrength = Double(strength)
    }

    func setNightShift(_ enabled: Bool) {
        if M7NightShiftSetEnabled(enabled) { nightShiftOn = enabled }
    }

    func setNightShiftStrength(_ strength: Double) {
        nightShiftStrength = strength
        _ = M7NightShiftSetStrength(Float(strength))
    }

    // MARK: Launch at login

    func readLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("M7 Control: could not change launch at login: \(error.localizedDescription)")
        }
        readLaunchAtLogin()
    }
}
