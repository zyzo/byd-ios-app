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
    var pending: Set<Control> = []
    var errorMessage: String?
    var importingKey = false

    let ble = AppServices.shared.ble
    let autoUnlock = AppServices.shared.autoUnlock
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

    func load(refresh: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            status = try await api.status(refresh: refresh)
            stale = false
            StatusCache.save(status)
            errorMessage = nil
            WidgetCenter.shared.reloadAllTimelines()
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

    /// Sends the command, then shows the expected result right away and
    /// re-reads the car a few seconds later to confirm it.
    private func perform(_ control: Control, _ command: CarCommand, expected: @escaping (inout CarStatus) -> Void) {
        guard !pending.contains(control) else { return }
        pending.insert(control)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CarStatus.self, from: data)
    }

    static func save(_ status: CarStatus?) {
        guard !AppConfig.demo else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try? encoder.encode(status), forKey: key)
    }
}
