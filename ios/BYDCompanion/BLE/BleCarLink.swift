import CoreBluetooth
import Foundation
import Observation
import WidgetKit

/// Direct Bluetooth link to the car using the dkey protocol (see BleCodec.swift).
/// Finds the car, authenticates, and sends lock/unlock/trunk/horn commands
/// without going through BYD's cloud.
@MainActor
@Observable
final class BleCarLink: NSObject {
    enum State: Equatable {
        case noKey
        case stopped
        case bluetoothOff
        case searching
        case connecting
        case authenticating
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .noKey: "Bluetooth key not set up"
            case .stopped: "Not looking for the car"
            case .bluetoothOff: "Bluetooth is off"
            case .searching: "Looking for the car…"
            case .connecting: "Connecting…"
            case .authenticating: "Authenticating…"
            case .ready: "Bluetooth ready"
            case .failed(let reason): reason
            }
        }
    }

    enum CommandError: LocalizedError {
        case notReady
        case writeFailed
        case rejected(UInt8)
        /// Sent, but the car never acknowledged it. It may still have acted.
        case unconfirmed

        var errorDescription: String? {
            switch self {
            case .notReady: "Bluetooth isn't connected to the car."
            case .writeFailed: "Couldn't send the Bluetooth command."
            case .rejected(let code): "The car refused the Bluetooth command (result \(code))."
            case .unconfirmed: "Sent over Bluetooth, but the car didn't confirm. Check the car before retrying."
            }
        }
    }

    private(set) var state: State = .noKey {
        didSet { publishReady() }
    }
    private(set) var hasKey = false
    /// Recent events, newest last, for troubleshooting.
    private(set) var log: [String] = []
    /// Latest signal strength from the car, in dBm, while connected.
    private(set) var rssi: Int?
    /// When the current authenticated session started.
    private(set) var readySince: Date?

    /// Called when the link becomes ready, when a ready link is lost, and on each signal reading.
    /// Append to subscribe.
    var onReady: [() -> Void] = []
    var onLinkLost: [() -> Void] = []
    var onRSSI: [(Int) -> Void] = []
    private(set) var lastCommandAt: Date?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var key: BleKey?
    private var session: BleSession?
    private var assembler = BleFrameAssembler()
    private var rejectedPeripherals: Set<UUID> = []
    private var wantsConnection = false

    private var payloadWaiter: (match: ([UInt8]) -> Bool, continuation: CheckedContinuation<[UInt8], Error>)?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var authTask: Task<Void, Never>?

    private static let serviceID = CBUUID(string: BleCodec.serviceUUID)
    private static let writeID = CBUUID(string: BleCodec.writeUUID)
    private static let notifyID = CBUUID(string: BleCodec.notifyUUID)
    private static let savedPeripheralKey = "ble.peripheral.id"
    private static let restoreID = "car-link"
    /// The signal `readRSSI()` reports in demo mode (dBm).
    var demoSignal = -58

    override init() {
        super.init()
        if AppConfig.demo {
            // A connected car, without touching Bluetooth.
            central = CBCentralManager(delegate: nil, queue: .main)
            hasKey = true
            state = .ready
            readySince = Date()
            log = DemoCar.log
            return
        }
        key = BleKeyStore.load()
        hasKey = key != nil
        // The restore identifier lets iOS relaunch the app in the background for the car.
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
        // A fresh process has no session yet, whatever the last one left behind.
        publishReady()
    }

    /// Tells the widget whether a Bluetooth session is up, and redraws it when that changes.
    private func publishReady() {
        let ready = state == .ready
        guard CarLinkState.ready != ready else { return }
        CarLinkState.ready = ready
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Public

    func installKey(_ newKey: BleKey) throws {
        try BleKeyStore.save(newKey)
        key = newKey
        hasKey = true
        note("Bluetooth key installed (key #\(newKey.keyNumber))")
        connect()
    }

    func removeKey() {
        disconnect()
        BleKeyStore.delete()
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        key = nil
        hasKey = false
        state = .noKey
    }

    func connect() {
        guard !AppConfig.demo else { return }
        guard key != nil else { state = .noKey; return }
        wantsConnection = true
        guard central.state == .poweredOn else {
            state = .bluetoothOff
            return
        }
        guard peripheral == nil || state != .ready else { return }
        findCar()
    }

    /// Stops searching for (or talking to) the car until the next connect().
    func stop() {
        disconnect()
        if key != nil { state = .stopped }
        note("Stopped looking for the car")
    }

    func disconnect() {
        guard !AppConfig.demo else { return }
        wantsConnection = false
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetLink()
    }

    /// Asks the car for the current signal strength; the answer arrives via `rssi` and `onRSSI`.
    func readRSSI() {
        guard state == .ready else { return }
        if AppConfig.demo {
            rssi = demoSignal + Int.random(in: -2 ... 2)
            onRSSI.forEach { $0(rssi!) }
            return
        }
        peripheral?.readRSSI()
    }

    /// Sends one control command and waits up to 3 s for the car's acknowledgement.
    func send(_ control: BleCodec.Control) async throws {
        lastCommandAt = Date()
        if AppConfig.demo {
            note("→ control 0x\(String(format: "%02X", control.rawValue))")
            try? await Task.sleep(for: .milliseconds(300))
            note("← control result 1")
            return
        }
        guard state == .ready, var current = session else { throw CommandError.notReady }
        let frame = current.controlFrame(control)
        session = current
        note("→ control 0x\(String(format: "%02X", control.rawValue))")
        do {
            try await write(frame)
        } catch {
            throw CommandError.writeFailed
        }
        let reply: [UInt8]
        do {
            reply = try await awaitPayload(timeout: 3) {
                $0.count > 3 && $0[0] == BleCodec.responseControl && $0[1] == BleCodec.controlCommandType && $0[2] == control.rawValue
            }
        } catch {
            throw CommandError.unconfirmed
        }
        note("← control result \(reply[3])")
        guard reply[3] == 0x01 else { throw CommandError.rejected(reply[3]) }
    }

    // MARK: Finding the car

    private func findCar() {
        if let saved = UserDefaults.standard.string(forKey: Self.savedPeripheralKey).flatMap(UUID.init),
           let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            note("Reconnecting to the known car")
            open(known)
            return
        }
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceID]).first {
            note("Car already connected to this iPhone")
            open(connected)
            return
        }
        state = .searching
        note("Scanning for the car")
        // No service filter: not every BYD advertises its service UUID, and iOS hides MAC addresses.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func looksLikeCar(_ advertisement: [String: Any], name: String?) -> Bool {
        if let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], services.contains(Self.serviceID) {
            return true
        }
        if let mac = key?.macAddress, let macBytes = BleCodec.hexBytes(mac.replacingOccurrences(of: ":", with: "")),
           let maker = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data {
            let bytes = [UInt8](maker)
            if bytes.contains(subsequence: macBytes) || bytes.contains(subsequence: macBytes.reversed()) { return true }
        }
        let advertisedName = (advertisement[CBAdvertisementDataLocalNameKey] as? String) ?? name ?? ""
        return advertisedName.uppercased().contains("BYD")
    }

    private func open(_ target: CBPeripheral) {
        central.stopScan()
        peripheral = target
        target.delegate = self
        state = .connecting
        central.connect(target)
    }

    private func resetLink() {
        let wasReady = state == .ready
        authTask?.cancel()
        authTask = nil
        failWaiters(CommandError.notReady)
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        session = nil
        assembler.reset()
        rssi = nil
        readySince = nil
        if key == nil {
            state = .noKey
        } else if [.ready, .searching, .connecting, .authenticating].contains(state) {
            // Callers that keep looking set .searching again afterwards.
            state = .stopped
        }
        if wasReady { onLinkLost.forEach { $0() } }
    }

    // MARK: Authentication

    private func authenticate() {
        guard let key else { return }
        state = .authenticating
        authTask = Task { [weak self] in
            guard let self else { return }
            do {
                note("→ wake")
                try await write(BleCodec.wakeUpFrame())
                try await Task.sleep(for: .milliseconds(200))

                let appRandom = BleCodec.randomBytes(8)
                note("→ random exchange (key #\(key.keyNumber))")
                try await write(BleCodec.randomExchangeFrame(keyNumber: UInt8(clamping: key.keyNumber), appRandom: appRandom))
                let random = try await awaitPayload(timeout: 5) {
                    $0.count >= 12 && $0[0] == BleCodec.responseRandomExchange && $0[1] == 0xD6
                }
                note("← random: keyState=\(random[2]) crc=\(random[11])")
                guard random[11] == 1 else { throw AuthError("The car rejected the key exchange") }
                guard random[2] == 1 else { throw AuthError("Bluetooth key isn't active in the car (state \(random[2]))") }
                guard let newSession = BleSession(dkeyHex: key.dkey, vehicleRandom: Array(random[3..<11]), appRandom: appRandom) else {
                    throw AuthError("The stored Bluetooth key is invalid")
                }
                session = newSession
                try await Task.sleep(for: .milliseconds(180))

                note("→ authenticate")
                try await write(newSession.authenticationFrame())
                let auth = try await awaitPayload(timeout: 5) {
                    $0.count >= 3 && $0[0] == BleCodec.responseAuthentication && $0[1] == 0xD8
                }
                note("← auth result \(auth[2])")
                guard auth[2] == 1 else { throw AuthError("The car refused the Bluetooth key (result \(auth[2]))") }

                if let id = peripheral?.identifier {
                    UserDefaults.standard.set(id.uuidString, forKey: Self.savedPeripheralKey)
                }
                state = .ready
                readySince = Date()
                note("Bluetooth ready")
                onReady.forEach { $0() }
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? AuthError)?.message ?? "Bluetooth authentication failed"
                note("✗ \(message)")
                state = .failed(message)
                if let peripheral { central.cancelPeripheralConnection(peripheral) }
            }
        }
    }

    private struct AuthError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: I/O helpers

    private func write(_ data: Data) async throws {
        guard let peripheral, let writeChar else { throw CommandError.notReady }
        // The car rejects the wake frame when forced to write-without-response,
        // so use acknowledged writes whenever the characteristic supports them.
        if writeChar.properties.contains(.write) {
            try await withCheckedThrowingContinuation { continuation in
                writeWaiter = continuation
                peripheral.writeValue(data, for: writeChar, type: .withResponse)
            }
        } else {
            peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
        }
    }

    private func awaitPayload(timeout: Double, matching match: @escaping ([UInt8]) -> Bool) async throws -> [UInt8] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.payloadWaiter?.continuation.resume(throwing: CommandError.unconfirmed)
            self?.payloadWaiter = nil
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            payloadWaiter = (match, continuation)
        }
    }

    private func failWaiters(_ error: Error) {
        payloadWaiter?.continuation.resume(throwing: error)
        payloadWaiter = nil
        writeWaiter?.resume(throwing: error)
        writeWaiter = nil
    }

    func note(_ message: String) {
        log.append(message)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleCarLink: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            // iOS relaunched the app in the background; pick up the car it was connected to.
            guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
            note("Restored by iOS in the background")
            peripheral = restored
            restored.delegate = self
            wantsConnection = key != nil
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if key != nil { connect() }
            case .unauthorized:
                state = .failed("Bluetooth permission denied in Settings")
            default:
                if key != nil { state = .bluetoothOff }
                resetLink()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard self.peripheral == nil, !rejectedPeripherals.contains(peripheral.identifier),
                  looksLikeCar(advertisementData, name: peripheral.name) else { return }
            note("Found \(peripheral.name ?? "unnamed device") (\(RSSI) dBm)")
            open(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            note("Connected; discovering services")
            peripheral.discoverServices([Self.serviceID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            note("✗ Connect failed: \(error?.localizedDescription ?? "unknown")")
            resetLink()
            state = .failed("Couldn't connect to the car")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            note("Disconnected")
            let wasFailure = if case .failed = state { true } else { false }
            resetLink()
            if wantsConnection && !wasFailure {
                state = .searching
                // Reconnect when the car comes back in range; iOS keeps this pending request.
                if let peripheral = central.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first {
                    open(peripheral)
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BleCarLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
                // Not the car after all; skip it and keep looking.
                note("Device has no BYD key service; skipping")
                rejectedPeripherals.insert(peripheral.identifier)
                central.cancelPeripheralConnection(peripheral)
                resetLink()
                if wantsConnection { findCar() }
                return
            }
            peripheral.discoverCharacteristics([Self.writeID, Self.notifyID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            writeChar = service.characteristics?.first { $0.uuid == Self.writeID }
            notifyChar = service.characteristics?.first { $0.uuid == Self.notifyID }
            guard let notifyChar, writeChar != nil else {
                state = .failed("The car's Bluetooth service is incomplete")
                return
            }
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                // An encrypted characteristic triggers iOS pairing; a refusal lands here.
                note("✗ Notifications: \(error.localizedDescription)")
                state = .failed("Pairing with the car failed")
                return
            }
            if characteristic.isNotifying { authenticate() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.notifyID, let value = characteristic.value else { return }
            for payload in assembler.append(value) {
                if let waiter = payloadWaiter, waiter.match(payload) {
                    payloadWaiter = nil
                    waiter.continuation.resume(returning: payload)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, state == .ready else { return }
            rssi = RSSI.intValue
            onRSSI.forEach { $0(RSSI.intValue) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                writeWaiter?.resume(throwing: error)
            } else {
                writeWaiter?.resume()
            }
            writeWaiter = nil
        }
    }
}

private extension Array where Element == UInt8 {
    func contains(subsequence: [UInt8]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        return (0...(count - subsequence.count)).contains { Array(self[$0..<$0 + subsequence.count]) == subsequence }
    }
}
