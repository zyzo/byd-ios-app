import Foundation
import Observation
import UserNotifications

/// Unlocks the car over Bluetooth as you walk up to it. Needs no location access.
///
/// - Losing the Bluetooth link starts the clock: you may be walking away. Driving away
///   (connected the whole time) never starts it.
/// - iOS keeps the reconnect request pending and wakes the app when the car is back in range,
///   even if the app was closed (not force-quit).
/// - If the link was gone for at least `minAway`, the app watches the signal; once it stays
///   stronger than the chosen distance's threshold, it sends one unlock over Bluetooth (never
///   through the cloud). Shorter dropouts (walls, the car's radio napping) never unlock.
@MainActor
@Observable
final class AutoUnlock {
    /// Unlock distances, in centimetres.
    static let distances = [50, 100, 200, 300, 500]

    /// Smoothed RSSI (dBm) that roughly matches each distance. Approximate:
    /// walls, pockets and bags weaken the signal.
    static let thresholds: [Int: Double] = [50: -55, 100: -62, 200: -67, 300: -71, 500: -76]

    /// "50 cm", "1 m", …
    static func label(_ centimetres: Int) -> String {
        centimetres < 100 ? "\(centimetres) cm" : "\(centimetres / 100) m"
    }
    /// The link must have been gone this long for a reconnect to count as coming back.
    static let minAway: TimeInterval = 5 * 60
    private static let holdTime: TimeInterval = 1.5
    /// Stop watching the signal if you don't approach within this long after reconnecting.
    private static let watchLimit: TimeInterval = 10 * 60

    private enum Keys {
        static let wanted = "autoUnlock.wanted"
        static let distance = "autoUnlock.distance"
        static let lostAt = "autoUnlock.lostAt"
    }

    private(set) var isOn: Bool
    var distance: Int {
        didSet { defaults.set(distance, forKey: Keys.distance) }
    }

    private let link: BleCarLink
    /// Another phone is driving the car (it holds the server's lease): never arm then.
    private let otherPhoneLeads: () -> Bool
    private let defaults = UserDefaults.standard
    /// When the link to the car dropped; kept across relaunches.
    private var lostAt: Date? {
        didSet { defaults.set(lostAt?.timeIntervalSince1970, forKey: Keys.lostAt) }
    }
    private var smoothed: Double?
    private var strongSince: Date?
    private var watchTimer: Timer?
    private var watchStarted: Date?

    init(link: BleCarLink, otherPhoneLeads: @escaping () -> Bool = { false }) {
        self.link = link
        self.otherPhoneLeads = otherPhoneLeads
        isOn = defaults.bool(forKey: Keys.wanted)
        var saved = defaults.integer(forKey: Keys.distance)
        if [1, 2, 3, 5].contains(saved) { saved *= 100 }  // older versions saved metres
        distance = Self.distances.contains(saved) ? saved : 100
        if let at = defaults.object(forKey: Keys.lostAt) as? Double {
            lostAt = Date(timeIntervalSince1970: at)
        }
        if AppConfig.demo {
            isOn = true
            return
        }

        link.onReady.append { [weak self] in self?.linkReady() }
        link.onLinkLost.append { [weak self] in self?.linkLost() }
        link.onRSSI.append { [weak self] in self?.evaluate($0) }
    }

    func enable() {
        isOn = true
        defaults.set(true, forKey: Keys.wanted)
        CarNotifications.requestQuietPermission()
        link.note("Auto-unlock switched on (≈\(Self.label(distance)))")
    }

    func disable() {
        isOn = false
        defaults.set(false, forKey: Keys.wanted)
        lostAt = nil
        stopWatching()
        link.note("Auto-unlock switched off")
    }

    private func linkLost() {
        stopWatching()
        guard isOn else { return }
        // Another phone is driving the car: you're probably a passenger.
        guard !otherPhoneLeads() else {
            lostAt = nil
            link.note("Auto-unlock not armed: another phone is driving the car")
            return
        }
        lostAt = Date()
    }

    private func linkReady() {
        guard isOn, let lostAt else { return }
        self.lostAt = nil
        let away = Date().timeIntervalSince(lostAt)
        guard away >= Self.minAway else {
            link.note("Auto-unlock: link was only gone \(Int(away)) s; not armed")
            return
        }
        link.note("Back near the car after \(Int(away / 60)) min away")
        startWatching()
    }

    private func startWatching() {
        guard watchTimer == nil else { return }
        smoothed = nil
        strongSince = nil
        watchStarted = Date()
        link.note("Auto-unlock: watching the signal (needs ≥ \(Int(Self.thresholds[distance] ?? -62)) dBm)")
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchTick() }
        }
    }

    private func watchTick() {
        if let watchStarted, Date().timeIntervalSince(watchStarted) > Self.watchLimit {
            link.note("Auto-unlock: you didn't come close; disarmed")
            stopWatching()
            return
        }
        link.readRSSI()
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        watchStarted = nil
        smoothed = nil
        strongSince = nil
    }

    private func evaluate(_ rssi: Int) {
        guard isOn, watchTimer != nil, let threshold = Self.thresholds[distance] else { return }
        let value = smoothed.map { 0.3 * Double(rssi) + 0.7 * $0 } ?? Double(rssi)
        smoothed = value
        guard value >= threshold else {
            strongSince = nil
            return
        }
        let since = strongSince ?? Date()
        strongSince = since
        if Date().timeIntervalSince(since) >= Self.holdTime { unlock(signal: Int(value)) }
    }

    private func unlock(signal: Int) {
        // One attempt per return, whatever the outcome.
        stopWatching()
        link.note("Auto-unlock: you're close (\(signal) dBm), unlocking")
        Task {
            do {
                try await link.send(.unlock)
                CarNotifications.post("Unlocked as you walked up")
            } catch BleCarLink.CommandError.unconfirmed {
                CarNotifications.post("Sent unlock as you walked up, but the car didn't confirm. Check the car.")
            } catch {
                CarNotifications.post("Auto-unlock didn't go through: \(error.localizedDescription)")
            }
        }
    }
}

/// Quiet notifications reporting what auto-unlock and auto-lock did.
enum CarNotifications {
    /// Provisional: no prompt, delivered silently to Notification Centre.
    static func requestQuietPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    static let leftUnlockedCategory = "left-unlocked"
    static let lockAction = "lock"

    /// Registers the Lock button that `postLeftUnlocked` offers.
    static func registerActions() {
        let lock = UNNotificationAction(identifier: lockAction, title: "Lock")
        let category = UNNotificationCategory(identifier: leftUnlockedCategory, actions: [lock], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func post(_ body: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = AppConfig.displayName
        content.body = body
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Long-press (or expand) it for a Lock button, which locks through the cloud.
    static func postLeftUnlocked(_ body: String) {
        post(body, category: leftUnlockedCategory)
    }
}
