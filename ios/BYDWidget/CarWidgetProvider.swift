import WidgetKit

struct CarEntry: TimelineEntry {
    var date: Date
    var status: CarStatus?
    /// Set when the server couldn't be reached: the numbers shown are old.
    var offline = false
    /// The command a widget button is sending right now, if any.
    var pending: CarCommand?
    /// The app is connected to the car over Bluetooth: its keys open the app to send that way.
    var bluetooth = false
}

/// Reads the car from the server for each timeline refresh. Commands sent from
/// the widget (CarWidgetIntents.swift) note what they changed in `RecentCommands`
/// so the next refresh shows the expected state even if BYD's cache lags.
struct CarProvider: TimelineProvider {
    private let api = CarAPI()

    func placeholder(in context: Context) -> CarEntry {
        CarEntry(date: .now, status: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarEntry) -> Void) {
        if context.isPreview {
            completion(CarEntry(date: .now, status: .sample))
            return
        }
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CarEntry>) -> Void) {
        Task {
            let entry = await entry()
            let next: Date
            if entry.pending != nil {
                // Check back soon in case the finishing reload is dropped.
                next = .now.addingTimeInterval(5)
            } else {
                next = Calendar.current.date(byAdding: .minute, value: entry.offline ? 5 : 15, to: .now)!
            }
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func entry() async -> CarEntry {
        let bluetooth = await Self.bluetoothReady()
        if let pending = RecentCommands.pending {
            if let task = InflightCommand.task {
                // A key was just tapped: redraw from what we already know, right away,
                // so the spinner doesn't wait for the server.
                if let status = RecentCommands.lastKnown {
                    return CarEntry(date: .now, status: status, pending: pending, bluetooth: bluetooth)
                }
                await task.value
            } else {
                // The extension was restarted mid-command, so its fate is unknown.
                // Not resent: the car may already have acted.
                RecentCommands.pending = nil
            }
        }
        do {
            var status = try await api.status()
            RecentCommands.overlay(on: &status)
            return CarEntry(date: .now, status: status, bluetooth: bluetooth)
        } catch {
            var status = RecentCommands.lastKnown
            if var s = status {
                RecentCommands.overlay(on: &s)
                status = s
            }
            return CarEntry(date: .now, status: status, offline: true, bluetooth: bluetooth)
        }
    }

    /// The app says its Bluetooth session is up, and iOS confirms the car is still connected.
    static func bluetoothReady() async -> Bool {
        guard CarLinkState.ready else { return false }
        return await BleProbe.carConnected()
    }
}

/// The command a widget key is sending, run in the extension after its intent has returned.
enum InflightCommand {
    static var task: Task<Void, Never>?

    static func start(_ command: CarCommand) {
        RecentCommands.pending = command
        task = Task {
            if (try? await CarAPI().run(command)) == true {
                RecentCommands.record(command)
            }
            RecentCommands.pending = nil
            task = nil
            WidgetCenter.shared.reloadTimelines(ofKind: CarWidget.kind)
        }
    }
}

/// What the widget last sent and last saw, kept in the extension's own defaults.
enum RecentCommands {
    private static let defaults = UserDefaults.standard
    private static let commandKey = "widget.lastCommand"
    private static let commandDateKey = "widget.lastCommandDate"
    private static let statusKey = "widget.lastStatus"
    private static let pendingKey = "widget.pendingCommand"
    private static let pendingDateKey = "widget.pendingCommandDate"
    /// BYD's cached status can lag a command by a while.
    private static let overlayWindow: TimeInterval = 90

    /// The command being sent right now. Forgotten after 100 s in case an intent is killed mid-way.
    static var pending: CarCommand? {
        get {
            guard let raw = defaults.string(forKey: pendingKey), let command = CarCommand(rawValue: raw) else { return nil }
            let since = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: pendingDateKey))
            return Date.now.timeIntervalSince(since) < 100 ? command : nil
        }
        set {
            defaults.set(newValue?.rawValue, forKey: pendingKey)
            defaults.set(Date.now.timeIntervalSinceReferenceDate, forKey: pendingDateKey)
        }
    }

    static func record(_ command: CarCommand) {
        defaults.set(command.rawValue, forKey: commandKey)
        defaults.set(Date.now.timeIntervalSinceReferenceDate, forKey: commandDateKey)
    }

    /// Applies the last command on top of `status` if it was sent recently, and remembers the result.
    static func overlay(on status: inout CarStatus) {
        if let raw = defaults.string(forKey: commandKey), let command = CarCommand(rawValue: raw) {
            let sent = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: commandDateKey))
            if Date.now.timeIntervalSince(sent) < overlayWindow {
                status.apply(command)
            }
        }
        if let data = try? encoder.encode(status) {
            defaults.set(data, forKey: statusKey)
        }
    }

    static var lastKnown: CarStatus? {
        guard let data = defaults.data(forKey: statusKey) else { return nil }
        return try? decoder.decode(CarStatus.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder { CarStatus.decoder }
}
