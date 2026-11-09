import Observation
import SwiftUI
import WidgetKit

@MainActor
@Observable
final class CarViewModel {
    /// What the car last reported, or what it reported last time the app ran until the server answers.
    var status: CarStatus? = StatusCache.load()
    var isRefreshing = false
    /// `status` came from the cache and the server hasn't confirmed it yet this run.
    var stale = true
    /// The app is asking the car for a fresh report on open; the server's copy stays usable meanwhile.
    var readingCar = false
    var pending: Set<Control> = []
    var errorMessage: String?
    var importingKey = false

    let ble = AppServices.shared.ble
    let autoUnlock = AppServices.shared.autoUnlock
    let autoLock = AppServices.shared.autoLock
    let trips = AppServices.shared.trips
    let tripLogger = AppServices.shared.tripLogger
    private let api = CarAPI()

    /// Fetches the Bluetooth key from the Mac server and stores it in the Keychain.
    func importBleKey() async {
        importingKey = true
        defer { importingKey = false }
        do {
            try ble.installKey(try await api.bleKey())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The server's copy can be up to its poll interval old, so ask the car itself when it is older than this on open.
    private static let openRefreshAge: TimeInterval = 5 * 60

    /// Shows the server's copy at once, then asks the car for a new report when that copy is old.
    func loadOnOpen() async {
        guard !isRefreshing else { return }
        await load()
        guard !stale, let updatedAt = status?.updatedAt,
              Date().timeIntervalSince(updatedAt) > Self.openRefreshAge else { return }
        readingCar = true
        defer { readingCar = false }
        await load(refresh: true, syncTrips: false)
    }

    func load(refresh: Bool = false, syncTrips: Bool = true) async {
        isRefreshing = true
        defer { isRefreshing = false }
        // The trip log syncs alongside, never holding up the car's status.
        if syncTrips { Task { await tripLogger.sync() } }
        do {
            status = try await api.status(refresh: refresh)
            stale = false
            StatusCache.save(status)
            errorMessage = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch is CancellationError {
            // SwiftUI cancels the view's load when it goes away or a refresh replaces it: not an error.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleLock() {
        let locked = status?.locked ?? true
        perform(.lock, locked ? .unlock : .lock) { $0.locked = !locked }
    }

    func toggleTrunk() {
        let open = status?.trunkOpen ?? false
        perform(.trunk, open ? .trunkClose : .trunkOpen) { $0.trunkOpen = !open }
    }

    func toggleWindows() {
        let open = status?.windowsOpen ?? false
        perform(.windows, open ? .windowsClose : .windowsOpen) { $0.windowsOpen = !open }
    }

    func toggleAC() {
        let on = status?.acOn ?? false
        perform(.ac, on ? .acStop : .acStart) { $0.acOn = !on }
    }

    func honk() {
        perform(.honk, .honk) { _ in }
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Runs the command a widget key handed to the app, if any. The widget only does that while
    /// the car is reachable over Bluetooth, so wait a moment for the link if it isn't ready yet
    /// (iOS may have just relaunched the app); failing that, `send` falls back to the cloud.
    func runHandoff() {
        guard let command = CarLinkState.takeHandoff() else { return }
        Task {
            if command.bleControl != nil, ble.hasKey {
                ble.connect()
                var waited = 0
                while ble.state != .ready, waited < 20 {
                    try? await Task.sleep(for: .milliseconds(200))
                    waited += 1
                }
            }
            run(command)
        }
    }

    /// Sends any command, showing the expected result like the on-screen keys do.
    func run(_ command: CarCommand) {
        perform(command.control, command) { $0.apply(command) }
    }

    /// Sends the command, then shows the expected result right away and
    /// re-reads the car a few seconds later to confirm it.
    private func perform(_ control: Control, _ command: CarCommand, expected: @escaping (inout CarStatus) -> Void) {
        guard !pending.contains(control) else { return }
        pending.insert(control)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if control == .lock { autoLock.manualCommandSent() }

        Task {
            defer { pending.remove(control) }
            do {
                guard try await send(command) else {
                    errorMessage = "The car didn't confirm “\(command.label)”."
                    return
                }
                if var updated = status {
                    expected(&updated)
                    status = updated
                }
                WidgetCenter.shared.reloadAllTimelines()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if control == .honk {
                    // Keep the tile lit while the horn sounds.
                    try? await Task.sleep(for: .seconds(2.5))
                }
                refreshSoon()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Direct Bluetooth when connected and supported, otherwise BYD's cloud.
    /// An unconfirmed Bluetooth command is not retried over the cloud: the car may already have acted.
    private func send(_ command: CarCommand) async throws -> Bool {
        if let control = command.bleControl, ble.state == .ready {
            do {
                try await ble.send(control)
                if AppConfig.demo { DemoCar.apply(command) }
                return true
            } catch BleCarLink.CommandError.unconfirmed {
                throw BleCarLink.CommandError.unconfirmed
            } catch {
                // Not sent or refused over Bluetooth: fall through to the cloud.
            }
        }
        return try await api.run(command)
    }

    private func refreshSoon() {
        Task {
            try? await Task.sleep(for: .seconds(8))
            await load(refresh: true)
        }
    }
}

/// The last status the server returned, kept so the app can show it right away on the next launch.
enum StatusCache {
    private static let key = "app.lastStatus"

    static func load() -> CarStatus? {
        guard !AppConfig.demo, let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? CarStatus.decoder.decode(CarStatus.self, from: data)
    }

    static func save(_ status: CarStatus?) {
        guard !AppConfig.demo else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try? encoder.encode(status), forKey: key)
    }
}
