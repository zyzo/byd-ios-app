import AppIntents
import WidgetKit

/// Runs one car command from a widget button, through the server (BYD's cloud).
/// Bluetooth isn't available to a widget extension, so these always go through the cloud.
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
        // Redraw the widget now with this button loading; WidgetKit reloads again when we return.
        RecentCommands.pending = command
        WidgetCenter.shared.reloadTimelines(ofKind: CarWidget.kind)
        defer { RecentCommands.pending = nil }
        let confirmed = try await CarAPI().run(command)
        if confirmed {
            RecentCommands.record(command)
        }
        return .result()
    }
}
