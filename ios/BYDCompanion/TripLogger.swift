import BackgroundTasks
import CoreLocation
import Foundation
import Observation
import UIKit

/// Tells the server when this phone gets in and out of the car, so trips get the exact
/// departure time, the parking spots and the phone that drove. The server derives the
/// trips themselves from the car's own reports; this only adds what the phone knows.
///
/// - Bluetooth ready: a `departure` event, and a lease on the car (renewed every 30 s).
/// - Link lost: an `arrival` event, then a background refresh about ten minutes later,
///   by which time the car has usually reported its arrival state.
/// - Events wait in the store's outbox until the phone is online.
@MainActor
@Observable
final class TripLogger {
    /// Registered in Info.plist under BGTaskSchedulerPermittedIdentifiers.
    static let refreshTaskID: String = {
        let listed = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return listed?.first ?? AppConfig.bundleID + ".trips.refresh"
    }()
    private static let leaseInterval: TimeInterval = 30
    private static let refreshDelay: TimeInterval = 10 * 60

    /// Driving since: the link came up and no arrival has been sent yet.
    private(set) var drivingSince: Date?
    private(set) var simulating = false

    private let link: BleCarLink
    private let store: TripStore
    private let carLocation: () -> CLLocationCoordinate2D?
    private var leaseRenewedAt: Date?
    private var knownTripIDs: Set<String>

    init(link: BleCarLink, store: TripStore, carLocation: @escaping () -> CLLocationCoordinate2D?) {
        self.link = link
        self.store = store
        self.carLocation = carLocation
        knownTripIDs = Set(store.trips.map(\.id))

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in self?.handle(task) }
        }

        link.onReady.append { [weak self] in self?.linkReady() }
        link.onLinkLost.append { [weak self] in self?.linkLost() }
        link.onRSSI.append { [weak self] _ in self?.renewLease() }

        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.foreground() }
        }
    }

    /// Flushes the outbox and refreshes the log; also run by `CarViewModel.load()`.
    func foreground() {
        Task { await sync() }
    }

    func sync() async {
        await store.flush()
        await store.refresh()
        noteNewTrips()
    }

    private func linkReady() {
        guard !AppConfig.demo || simulating else { return }
        drivingSince = Date()
        enqueue(.departure)
        Task {
            await store.flush()
            await store.requestLease()
            leaseRenewedAt = Date()
        }
    }

    private func renewLease() {
        guard link.state == .ready, drivingSince != nil else { return }
        if let last = leaseRenewedAt, Date().timeIntervalSince(last) < Self.leaseInterval { return }
        leaseRenewedAt = Date()
        Task { await store.requestLease() }
    }

    private func linkLost() {
        guard drivingSince != nil else { return }
        drivingSince = nil
        enqueue(.arrival)
        Task { await store.flush() }
        scheduleRefresh(after: Self.refreshDelay)
    }

    private func enqueue(_ kind: PhoneEvent.Kind) {
        let spot = carLocation()
        store.enqueue(PhoneEvent(kind: kind, at: Date(), lat: spot?.latitude, lon: spot?.longitude))
        link.note("Trip log: \(kind.rawValue) noted")
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        guard !AppConfig.demo else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(delay)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGAppRefreshTask) {
        let work = Task { await sync() }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    /// A quiet notification for each trip that closed since the last look, when asked for.
    private func noteNewTrips() {
        let current = Set(store.trips.map(\.id))
        let fresh = current.subtracting(knownTripIDs)
        // On the first sync every trip is new; don't announce the whole history.
        let firstLook = knownTripIDs.isEmpty
        knownTripIDs = current
        guard store.settings.notifyOnTrip, !fresh.isEmpty, !firstLook else { return }
        for trip in store.trips where fresh.contains(trip.id) {
            var parts = ["\(Int(trip.km.rounded())) km"]
            if trip.litres == 0, trip.kwh > 0 { parts.append("all electric") }
            if let cost = trip.cost { parts.append("≈ " + Money.kdong(cost.total)) }
            CarNotifications.post("Trip logged: " + parts.joined(separator: ", "))
        }
    }

    /// Demo mode: runs the real departure → drive → arrival path on the pretend car.
    func simulateTrip() async {
        guard AppConfig.demo, !simulating else { return }
        simulating = true
        defer { simulating = false }
        linkReady()
        try? await Task.sleep(for: .seconds(1))
        DemoCar.drive()
        linkLost()
        await sync()
    }
}
