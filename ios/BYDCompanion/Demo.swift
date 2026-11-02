import Foundation

/// Demo mode: sample data instead of a real car, for screenshots and trying the UI.
/// Turn it on with the launch argument `-demo YES` (Xcode › Scheme › Run › Arguments).
@MainActor
enum DemoCar {
    static var status = CarStatus(
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

    static let log = [
        "Reconnecting to the known car",
        "Connected; discovering services",
        "→ wake",
        "→ random exchange (key #0)",
        "← random: keyState=1 crc=1",
        "→ authenticate",
        "← auth result 1",
        "Bluetooth ready",
    ]

    static func apply(_ command: CarCommand) {
        switch command {
        case .lock: status.locked = true
        case .unlock: status.locked = false
        case .trunkOpen: status.trunkOpen = true
        case .trunkClose: status.trunkOpen = false
        case .windowsOpen: status.windowsOpen = true
        case .windowsClose: status.windowsOpen = false
        case .acStart: status.acOn = true
        case .acStop: status.acOn = false
        case .honk: break
        }
    }
}
