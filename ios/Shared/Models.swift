import Foundation

/// Mirrors the JSON returned by `GET /status` on the backend (server.py).
struct CarStatus: Codable, Equatable {
    var model: String?
    var plate: String?
    var batteryPercent: Double?
    /// Fuel level, percent of the tank. Not reported by every car.
    var fuelPercent: Double?
    var rangeTotalKm: Double?
    var rangeElectricKm: Double?
    var rangeFuelKm: Double?
    var odometerKm: Double?
    var locked: Bool?
    var trunkOpen: Bool?
    var windowsOpen: Bool?
    var acOn: Bool?
    var charging: Bool?
    var powerOn: Bool?
    var speedKmh: Double?
    var anyDoorOpen: Bool?
    var tyresBar: Tyres
    /// When the car produced the data, and when the server received it.
    var updatedAt: Date?
    var receivedAt: Date?
    /// A refresh was asked for and the car didn't answer with anything newer.
    var stale: Bool?
    /// `push`, `poll` or `projection` (see README, "What the server returns").
    var source: String?

    struct Tyres: Codable, Equatable {
        var frontLeft: Double?
        var frontRight: Double?
        var rearLeft: Double?
        var rearRight: Double?
    }

    /// The state the car should be in once `command` has taken effect.
    mutating func apply(_ command: CarCommand) {
        switch command {
        case .lock: locked = true
        case .unlock: locked = false
        case .trunkOpen: trunkOpen = true
        case .trunkClose: trunkOpen = false
        case .windowsOpen: windowsOpen = true
        case .windowsClose: windowsOpen = false
        case .acStart: acOn = true
        case .acStop: acOn = false
        case .honk: break
        }
    }

    /// Sample car for demo mode, widget placeholders and previews.
    static let sample = CarStatus(
        model: "Sealion 6",
        plate: nil,
        batteryPercent: 78,
        fuelPercent: 61,
        rangeTotalKm: 812,
        rangeElectricKm: 74,
        rangeFuelKm: 738,
        odometerKm: 12_480,
        locked: true,
        trunkOpen: false,
        windowsOpen: false,
        acOn: false,
        charging: false,
        powerOn: false,
        speedKmh: 0,
        anyDoorOpen: false,
        tyresBar: .init(frontLeft: 2.5, frontRight: 2.5, rearLeft: 2.4, rearRight: 2.5),
        // Matches the 9:41 status bar used for screenshots.
        updatedAt: Calendar.current.date(bySettingHour: 9, minute: 40, second: 0, of: Date()),
        receivedAt: Date(),
        stale: false,
        source: "push"
    )

    /// Decodes the server's JSON. Its timestamps are ISO 8601 with or without fractional seconds.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }
}

/// Command names accepted by `POST /command/{name}`.
enum CarCommand: String {
    case lock, unlock
    case trunkOpen = "trunk_open"
    case trunkClose = "trunk_close"
    case windowsOpen = "windows_open"
    case windowsClose = "windows_close"
    case acStart = "ac_start"
    case acStop = "ac_stop"
    case honk

    var label: String {
        switch self {
        case .lock: "Lock"
        case .unlock: "Unlock"
        case .trunkOpen: "Open trunk"
        case .trunkClose: "Close trunk"
        case .windowsOpen: "Open windows"
        case .windowsClose: "Close windows"
        case .acStart: "Start A/C"
        case .acStop: "Stop A/C"
        case .honk: "Honk"
        }
    }

    /// The on-screen key that sends this command.
    var control: Control {
        switch self {
        case .lock, .unlock: .lock
        case .trunkOpen, .trunkClose: .trunk
        case .windowsOpen, .windowsClose: .windows
        case .acStart, .acStop: .ac
        case .honk: .honk
        }
    }

    /// Whether the car's Bluetooth key can send this (the dkey controls in BleCodec.swift).
    var worksOverBluetooth: Bool {
        switch self {
        case .lock, .unlock, .trunkOpen, .honk: true
        default: false
        }
    }
}

/// One control on the home screen; used to track which one is busy.
enum Control: Hashable {
    case lock, trunk, windows, ac, honk
}

/// The car's Bluetooth key (from provision_ble_key.py). Stored only in the iOS Keychain.
struct BleKey: Codable, Equatable {
    var vin: String
    var macAddress: String?
    var dkey: String
    var keyNumber: Int
    var keyValidTo: Double?
}
