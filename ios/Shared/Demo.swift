import Foundation

/// Demo mode: sample data instead of a real car, for screenshots and trying the UI.
/// Turn it on with the launch argument `-demo YES` (Xcode › Scheme › Run › Arguments).
@MainActor
enum DemoCar {
    static var status = CarStatus.sample

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
        status.apply(command)
    }
}
