import WidgetKit

struct CarEntry: TimelineEntry {
    var date: Date
    var status: CarStatus?
    /// Set when the server couldn't be reached: the numbers shown are old.
    var offline = false
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
            let next = Calendar.current.date(byAdding: .minute, value: entry.offline ? 5 : 15, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func entry() async -> CarEntry {
        do {
            var status = try await api.status()
            RecentCommands.overlay(on: &status)
            return CarEntry(date: .now, status: status)
        } catch {
            var status = RecentCommands.lastKnown
            if var s = status {
                RecentCommands.overlay(on: &s)
                status = s
            }
            return CarEntry(date: .now, status: status, offline: true)
        }
    }
}

/// What the widget last sent and last saw, kept in the extension's own defaults.
enum RecentCommands {
    private static let defaults = UserDefaults.standard
    private static let commandKey = "widget.lastCommand"
    private static let commandDateKey = "widget.lastCommandDate"
    private static let statusKey = "widget.lastStatus"
    /// BYD's cached status can lag a command by a while.
    private static let overlayWindow: TimeInterval = 90

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

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
