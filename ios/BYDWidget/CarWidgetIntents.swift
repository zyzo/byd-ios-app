import AppIntents
import WidgetKit

/// Runs one car command from a widget button, through the server (BYD's cloud),
/// without leaving the Home Screen. A widget extension can't use the app's Bluetooth
/// session; when that session is up the keys use CarBluetoothCommandIntent instead.
struct CarCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Send a car command"
    static let isDiscoverable = false

    @Parameter(title: "Command")
    var command: String

    init() {}

    init(_ command: CarCommand) {
        self.command = command.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let command = CarCommand(rawValue: command) else { return .result() }
        // WidgetKit only redraws once perform() returns, so return at once with the
        // key marked as sending; the command carries on in the extension (InflightCommand)
        // and reloads the widget again when it is done.
        InflightCommand.start(command)
        return .result()
    }
}

/// Opens the app to send one car command over its Bluetooth link to the car. Shown on
/// the widget's keys while the app is connected (CarEntry.bluetooth). The app falls
/// back to the cloud itself if the link has dropped by the time it opens.
struct CarBluetoothCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Send a car command over Bluetooth"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Command")
    var command: String

    init() {}

    init(_ command: CarCommand) {
        self.command = command.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let command = CarCommand(rawValue: command) {
            CarLinkState.handOff(command)
        }
        return .result()
    }
}
