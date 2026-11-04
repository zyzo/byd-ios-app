import Foundation

/// Mirrors the JSON returned by `GET /status` on the backend (server.py).
struct CarStatus: Codable, Equatable {
    var model: String?
    var plate: String?
    var batteryPercent: Double?
    var rangeTotalKm: Double?
    var rangeElectricKm: Double?
    var rangeFuelKm: Double?
    var odometerKm: Double?
    var locked: Bool?
    var trunkOpen: Bool?
    var windowsOpen: Bool?
    var acOn: Bool?
    var charging: Bool?
    var tyresBar: Tyres
    var updatedAt: Date?

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
        rangeTotalKm: 812,
        rangeElectricKm: 74,
        rangeFuelKm: 738,
        odometerKm: 12_480,
        locked: true,
        trunkOpen: false,
        windowsOpen: false,
        acOn: false,
        charging: false,
        tyresBar: .init(frontLeft: 2.5, frontRight: 2.5, rearLeft: 2.4, rearRight: 2.5),
        // Matches the 9:41 status bar used for screenshots.
        updatedAt: Calendar.current.date(bySettingHour: 9, minute: 40, second: 0, of: Date())
    )
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
