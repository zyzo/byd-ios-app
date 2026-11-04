import CoreBluetooth

/// Asks iOS whether this iPhone currently has a Bluetooth connection to the car.
/// The app owns that connection; the widget only looks, to confirm the app's
/// "ready" flag (CarLinkState) isn't left over from a process iOS has since killed.
final class BleProbe: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private var continuation: CheckedContinuation<Bool, Never>?

    static func carConnected() async -> Bool {
        if AppConfig.demo { return true }
        let probe = BleProbe()
        return await probe.run()
    }

    private func run() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            // Bluetooth normally reports its state within a few ms; don't hold the widget up if not.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish(false) }
        }
    }

    private func finish(_ connected: Bool) {
        continuation?.resume(returning: connected)
        continuation = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown, central.state != .resetting else { return }
        guard central.state == .poweredOn else { finish(false); return }
        let car = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: CarLinkState.serviceUUID)])
        finish(!car.isEmpty)
    }
}
