import Foundation
import Observation

/// The phone's copy of the trip log. The server is the system of record; this mirrors
/// `GET /trips` and `/settings` into the App Group (`trips.json`) so the sheet opens at
/// once, offline too, and keeps an outbox of this phone's departure/arrival events.
@MainActor
@Observable
final class TripStore {
    private(set) var trips: [Trip] = []
    private(set) var charges: [Charge] = []
    private(set) var openTrip: Trip?
    private(set) var settings = EnergySettings()
    private(set) var prices: Prices?
    private(set) var phones: [Phone] = []
    /// The lease the server last reported, and when we heard it.
    private(set) var leader: Leader?
    private(set) var leaderSeenAt: Date?
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var outbox: [PhoneEvent] = []
    var errorMessage: String?

    /// Another phone held the car's lease within the last two minutes.
    var otherPhoneLeads: Bool {
        guard let leader, let seen = leaderSeenAt, leader.phoneId != PhoneIdentity.id else { return false }
        if let until = leader.until, until < Date() { return false }
        return Date().timeIntervalSince(seen) < 2 * 60
    }

    private let api: CarAPI
    private var flushing = false

    init(api: CarAPI = CarAPI()) {
        self.api = api
        if let mirror = Mirror.load() {
            trips = mirror.trips
            charges = mirror.charges ?? []
            openTrip = mirror.openTrip
            settings = mirror.settings
            prices = mirror.prices
            phones = mirror.phones
            leader = mirror.leader
            leaderSeenAt = mirror.leaderSeenAt
            lastRefresh = mirror.lastRefresh
            outbox = mirror.outbox
        }
    }

    /// Pulls trips changed since the last refresh and merges them; soft-deleted ones are dropped.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await api.trips(since: lastRefresh)
            merge(response)
            lastRefresh = response.serverTime ?? Date()
            errorMessage = nil
            save()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func merge(_ response: TripsResponse) {
        var byId = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
        for trip in response.trips {
            if trip.deletedAt != nil {
                byId.removeValue(forKey: trip.id)
            } else {
                byId[trip.id] = trip
            }
        }
        trips = byId.values.sorted { ($0.endAt ?? $0.startAt) > ($1.endAt ?? $1.startAt) }
        var chargesById = Dictionary(uniqueKeysWithValues: charges.map { ($0.id, $0) })
        for charge in response.charges ?? [] {
            chargesById[charge.id] = charge.deletedAt == nil ? charge : nil
        }
        charges = chargesById.values.sorted { $0.endAt > $1.endAt }
        openTrip = response.openTrip
        if let settings = response.settings { self.settings = settings }
    }

    func delete(_ trip: Trip) async {
        trips.removeAll { $0.id == trip.id }
        save()
        do {
            try await api.deleteTrip(trip.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Corrects a refuel or a charge on the way; nil for both goes back to the estimate.
    func editRefill(_ trip: Trip, _ kind: Refill.Kind, amount: Double?, cost: Double?) async {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        var refills = trips[index].refills ?? TripRefills()
        refills[kind] = amount == nil && cost == nil ? nil : TripRefills.Edit(amount: amount, cost: cost)
        trips[index].refills = refills.fuel == nil && refills.charge == nil ? nil : refills
        save()
        do {
            if let saved = try await api.editRefill(trip.id, kind: kind, amount: amount, cost: cost),
               let index = trips.firstIndex(where: { $0.id == saved.id }) {
                trips[index] = saved
                save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Corrects a charge between trips; nil for both goes back to the estimate.
    func editCharge(_ charge: Charge, amount: Double?, cost: Double?) async {
        guard let index = charges.firstIndex(where: { $0.id == charge.id }) else { return }
        charges[index].edit = amount == nil && cost == nil ? nil : TripRefills.Edit(amount: amount, cost: cost)
        save()
        do {
            if let saved = try await api.editCharge(charge.id, amount: amount, cost: cost),
               let index = charges.firstIndex(where: { $0.id == saved.id }) {
                charges[index] = saved
                save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The charge while the car stood after `trip`: it begins where the trip ended.
    func charge(after trip: Trip) -> Charge? {
        guard let odoEnd = trip.odoEnd else { return nil }
        return charges.first { $0.odometerKm == odoEnd }
    }

    /// Charges with no trip before them in the log, shown on their own.
    func unattachedCharges(_ charges: [Charge]) -> [Charge] {
        let ends = Set(trips.compactMap(\.odoEnd))
        return charges.filter { !ends.contains($0.odometerKm) }
    }

    /// For a rise that wasn't a charge.
    func delete(_ charge: Charge) async {
        charges.removeAll { $0.id == charge.id }
        save()
        do {
            try await api.deleteCharge(charge.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSettings() async {
        if let fetched = try? await api.settings() {
            settings = fetched
            save()
        }
    }

    func update(_ settings: EnergySettings) async {
        self.settings = settings
        save()
        do {
            self.settings = try await api.updateSettings(settings)
            save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPrices() async {
        if let fetched = try? await api.prices() {
            prices = fetched
            save()
        }
    }

    func loadPhones() async {
        if let response = try? await api.phones() {
            phones = response.phones
            noteLeader(response.leader)
            save()
        }
    }

    /// Asks the server for the car's lease; the answer says who leads either way.
    @discardableResult
    func requestLease() async -> Bool {
        guard let response = try? await api.lease() else { return false }
        noteLeader(response.leader)
        save()
        return response.granted
    }

    private func noteLeader(_ leader: Leader?) {
        self.leader = leader
        leaderSeenAt = leader == nil ? nil : Date()
    }

    /// Queues an event for `flush()`.
    func enqueue(_ event: PhoneEvent) {
        outbox.append(event)
        save()
    }

    /// Sends queued events; the ones the server didn't take stay queued.
    func flush() async {
        guard !flushing, !outbox.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let batch = outbox
        do {
            try await api.postEvents(batch)
            outbox.removeAll { event in batch.contains { $0.id == event.id } }
            save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The petrol price in force: the override, else what the server fetched.
    var petrolPrice: Double? {
        settings.petrolOverrideVndPerLitre ?? prices?.petrol?.vndPerLitre
    }

    private func save() {
        Mirror(
            trips: trips, charges: charges, openTrip: openTrip, settings: settings, prices: prices, phones: phones,
            leader: leader, leaderSeenAt: leaderSeenAt, lastRefresh: lastRefresh, outbox: outbox
        ).save()
    }

    /// What `trips.json` in the App Group holds.
    struct Mirror: Codable {
        var trips: [Trip]
        var charges: [Charge]?
        var openTrip: Trip?
        var settings: EnergySettings
        var prices: Prices?
        var phones: [Phone]
        var leader: Leader?
        var leaderSeenAt: Date?
        var lastRefresh: Date?
        var outbox: [PhoneEvent]

        static var url: URL? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroup)?
                .appending(path: AppConfig.demo ? "trips-demo.json" : "trips.json")
        }

        static func load() -> Mirror? {
            guard !AppConfig.demo, let url, let data = try? Data(contentsOf: url) else { return nil }
            return try? CarStatus.decoder.decode(Mirror.self, from: data)
        }

        func save() {
            guard !AppConfig.demo, let url = Self.url else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(self).write(to: url, options: .atomic)
        }
    }
}
