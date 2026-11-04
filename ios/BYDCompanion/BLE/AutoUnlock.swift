import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// Unlocks the car over Bluetooth as you walk up to it.
///
/// - A geofence around where the car was last parked wakes the app, even when it's closed.
/// - Leaving that area while not connected to the car "arms" auto-unlock. Driving away
///   (connected the whole time) never arms it.
/// - Coming back reconnects Bluetooth; once the car's signal stays stronger than the chosen
///   distance's threshold, it sends one unlock over Bluetooth (never through the cloud) and disarms.
@MainActor
@Observable
final class AutoUnlock: NSObject {
    /// Unlock distances, in centimetres.
    static let distances = [50, 100, 200, 300, 500]

    /// Smoothed RSSI (dBm) that roughly matches each distance. Approximate:
    /// walls, pockets and bags weaken the signal.
    static let thresholds: [Int: Double] = [50: -55, 100: -62, 200: -67, 300: -71, 500: -76]

    /// "50 cm", "1 m", …
    static func label(_ centimetres: Int) -> String {
        centimetres < 100 ? "\(centimetres) cm" : "\(centimetres / 100) m"
    }
    private static let regionID = "parked-car"
    private static let regionRadius: CLLocationDistance = 150
    private static let holdTime: TimeInterval = 1.5
    /// Stop watching the signal if you don't approach within this long after reconnecting.
    private static let watchLimit: TimeInterval = 10 * 60

    private enum Keys {
        static let wanted = "autoUnlock.wanted"
        static let distance = "autoUnlock.distance"
        static let armedAt = "autoUnlock.armedAt"
        static let carLat = "autoUnlock.carLat"
        static let carLon = "autoUnlock.carLon"
    }

    /// The person switched it on (permission may still be missing).
    private(set) var wanted: Bool
    var distance: Int {
        didSet { defaults.set(distance, forKey: Keys.distance) }
    }
    private(set) var authorization: CLAuthorizationStatus
    /// A permission prompt is showing or about to.
    private(set) var requesting = false
    private(set) var carLocation: CLLocationCoordinate2D?

    var isOn: Bool { wanted && authorization == .authorizedAlways }
    /// Switched on, but location isn't set to Always.
    var needsAlways: Bool {
        wanted && !requesting && authorization != .authorizedAlways && authorization != .notDetermined
    }

    private let link: BleCarLink
    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private var armedAt: Date? {
        didSet { defaults.set(armedAt?.timeIntervalSince1970, forKey: Keys.armedAt) }
    }
    private var smoothed: Double?
    private var strongSince: Date?
    private var watchTimer: Timer?
    private var watchStarted: Date?

    init(link: BleCarLink) {
        self.link = link
        wanted = defaults.bool(forKey: Keys.wanted)
        var saved = defaults.integer(forKey: Keys.distance)
        if [1, 2, 3, 5].contains(saved) { saved *= 100 }  // older versions saved metres
        distance = Self.distances.contains(saved) ? saved : 100
        authorization = manager.authorizationStatus
        if let at = defaults.object(forKey: Keys.armedAt) as? Double {
            armedAt = Date(timeIntervalSince1970: at)
        }
        if let lat = defaults.object(forKey: Keys.carLat) as? Double, let lon = defaults.object(forKey: Keys.carLon) as? Double {
            carLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        super.init()
        if AppConfig.demo {
            wanted = true
            authorization = .authorizedAlways
            carLocation = CLLocationCoordinate2D(latitude: 10.7769, longitude: 106.7009)
            return
        }
        manager.delegate = self

        link.onReady.append { [weak self] in self?.linkReady() }
        link.onLinkLost.append { [weak self] in self?.linkLost() }
        link.onRSSI.append { [weak self] in self?.evaluate($0) }

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
        updateRegion()
    }

    func enable() {
        if AppConfig.demo { wanted = true; return }
        wanted = true
        defaults.set(true, forKey: Keys.wanted)
        CarNotifications.requestQuietPermission()
        switch authorization {
        case .notDetermined:
            requesting = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            requesting = true
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        link.note("Auto-unlock switched on (≈\(Self.label(distance)))")
        updateRegion()
        if isOn, link.state == .ready { manager.requestLocation() }
    }

    func disable() {
        wanted = false
        defaults.set(false, forKey: Keys.wanted)
        armedAt = nil
        stopWatching()
        link.note("Auto-unlock switched off")
        updateRegion()
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func appBecameActive() {
        authorization = manager.authorizationStatus
        guard requesting else { return }
        // A dismissed prompt makes the app active again; if no second prompt follows, we're done asking.
        Task {
            try? await Task.sleep(for: .seconds(1))
            if UIApplication.shared.applicationState == .active { requesting = false }
        }
    }

    private func updateRegion() {
        for region in manager.monitoredRegions where region.identifier == Self.regionID {
            manager.stopMonitoring(for: region)
        }
        guard isOn, let carLocation else { return }
        let region = CLCircularRegion(center: carLocation, radius: Self.regionRadius, identifier: Self.regionID)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    /// Connected to the car means the phone is at the car: remember that spot.
    private func linkReady() {
        guard isOn else { return }
        manager.requestLocation()
        if isArmed { startWatching() }
    }

    /// Walking away: remember where the car was left.
    private func linkLost() {
        stopWatching()
        guard isOn else { return }
        manager.requestLocation()
    }

    private var isArmed: Bool {
        guard let armedAt else { return false }
        guard let readySince = link.readySince else { return true }
        // Only a connection made after you left counts.
        return readySince > armedAt
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
            armedAt = nil
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
        guard isOn, isArmed, watchTimer != nil, let threshold = Self.thresholds[distance] else { return }
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
        // Disarm first: one attempt per return, whatever the outcome.
        armedAt = nil
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

    static func post(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = AppConfig.displayName
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension AutoUnlock: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorization = manager.authorizationStatus
            switch authorization {
            case .authorizedWhenInUse where wanted && requesting:
                // Second step: iOS offers "Change to Always Allow".
                manager.requestAlwaysAuthorization()
            case .authorizedAlways, .denied, .restricted:
                requesting = false
            default:
                break
            }
            updateRegion()
            if isOn, link.state == .ready { manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard isOn, let spot = locations.last?.coordinate else { return }
            carLocation = spot
            defaults.set(spot.latitude, forKey: Keys.carLat)
            defaults.set(spot.longitude, forKey: Keys.carLon)
            updateRegion()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { link.note("Location unavailable: \(error.localizedDescription)") }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        MainActor.assumeIsolated {
            guard isOn, region.identifier == Self.regionID else { return }
            // Connected while leaving means you're driving the car: don't arm.
            guard link.state != .ready else { return }
            armedAt = Date()
            link.note("Auto-unlock armed: you left the car's area")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        MainActor.assumeIsolated {
            guard isOn, region.identifier == Self.regionID, armedAt != nil else { return }
            link.note("Back near the car: connecting")
            link.connect()
        }
    }
}
