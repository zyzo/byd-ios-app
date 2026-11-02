import Foundation

/// Mirrors the JSON returned by `GET /status` on the backend (server.py).
struct CarStatus: Decodable, Equatable {
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

    struct Tyres: Decodable, Equatable {
        var frontLeft: Double?
        var frontRight: Double?
        var rearLeft: Double?
        var rearRight: Double?
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

    /// The direct-Bluetooth equivalent, for the commands the dkey protocol supports.
    var bleControl: BleCodec.Control? {
        switch self {
        case .lock: .lock
        case .unlock: .unlock
        case .trunkOpen: .trunkOpen
        case .honk: .lightsAndHorn
        default: nil
        }
    }

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
}

/// One control on the home screen; used to track which one is busy.
enum Control: Hashable {
    case lock, trunk, windows, ac, honk
}
