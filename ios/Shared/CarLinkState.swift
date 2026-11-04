import Foundation

/// What the app tells the widget about its Bluetooth link to the car, through the
/// App Group's shared defaults, and the command a widget key hands to the app.
enum CarLinkState {
    static let serviceUUID = "42594420-4155-544F-E0A9-E50E24DCCA9E"

    private static let defaults = UserDefaults(suiteName: AppConfig.appGroup)
    private static let readyKey = "link.ready"
    private static let handoffKey = "link.handoff"
    private static let handoffDateKey = "link.handoffDate"

    /// True while the app holds an authenticated Bluetooth session with the car.
    /// Written by the app; the widget confirms it against the live Bluetooth connection.
    static var ready: Bool {
        get { defaults?.bool(forKey: readyKey) ?? false }
        set { defaults?.set(newValue, forKey: readyKey) }
    }

    /// A command tapped on the widget while the car was reachable over Bluetooth,
    /// for the app to run when it opens. Forgotten after 30 s.
    static func handOff(_ command: CarCommand) {
        defaults?.set(command.rawValue, forKey: handoffKey)
        defaults?.set(Date.now.timeIntervalSinceReferenceDate, forKey: handoffDateKey)
    }

    static func takeHandoff() -> CarCommand? {
        defer {
            defaults?.removeObject(forKey: handoffKey)
            defaults?.removeObject(forKey: handoffDateKey)
        }
        guard let raw = defaults?.string(forKey: handoffKey), let command = CarCommand(rawValue: raw) else { return nil }
        let since = Date(timeIntervalSinceReferenceDate: defaults?.double(forKey: handoffDateKey) ?? 0)
        return Date.now.timeIntervalSince(since) < 30 ? command : nil
    }
}
