import Observation
import SwiftUI

@MainActor
@Observable
final class CarViewModel {
    var status: CarStatus?
    var isRefreshing = false
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
            errorMessage = nil
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
