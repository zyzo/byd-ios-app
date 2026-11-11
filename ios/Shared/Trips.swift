import Foundation
import Security
import UIKit

/// One drive, as the server derives it from the car's reports (`GET /trips`).
/// Energy comes from the battery and fuel percentages at departure and arrival.
struct Trip: Codable, Identifiable, Equatable {
    enum Flag: String {
        case chargedDuringTrip, refuelledDuringTrip, tooShortToMeasure, coarse
    }

    var id: String
    var startAt: Date
    var endAt: Date?
    var km: Double
    var odoStart: Double?
    var odoEnd: Double?
    var socStart: Double?
    var socEnd: Double?
    var fuelStart: Double?
    var fuelEnd: Double?
    var kwh: Double
    var litres: Double
    var evKm: Double
    var petrolKm: Double
    var electricShare: Double
    var cost: TripCost?
    var phoneId: String?
    var phoneName: String?
    var startLocation: TripLocation?
    var endLocation: TripLocation?
    var flags: [String]
    /// `car` (power on/off pair) or `coarse` (odometer jump with no pair).
    var source: String
    var deletedAt: Date?
    /// What a refuel or a charge on the way really came to, where someone corrected the estimate.
    var refills: TripRefills? = nil

    func has(_ flag: Flag) -> Bool { flags.contains(flag.rawValue) }
    var withoutPhone: Bool { phoneId == nil }
    var tooShort: Bool { has(.tooShortToMeasure) }
    var isOpen: Bool { endAt == nil }
    var duration: TimeInterval? { endAt.map { $0.timeIntervalSince(startAt) } }
    /// Trips are grouped by when they ended; an open trip by when it started.
    var day: Date { Calendar.current.startOfDay(for: endAt ?? startAt) }
}

/// `refills` on a trip: corrections by kind; a nil value falls back to the estimate.
struct TripRefills: Codable, Equatable {
    struct Edit: Codable, Equatable {
        /// Litres for fuel, kWh for a charge.
        var amount: Double?
        /// Dong.
        var cost: Double?
    }

    var fuel: Edit?
    var charge: Edit?

    subscript(kind: Refill.Kind) -> Edit? {
        get { kind == .fuel ? fuel : charge }
        set { if kind == .fuel { fuel = newValue } else { charge = newValue } }
    }
}

/// A refuel or a charge during a trip. Estimated from how far the gauge rose, times the tank or
/// battery size and the trip's price, unless someone entered what it really came to.
struct Refill: Equatable {
    enum Kind: String, Codable {
        case fuel, charge
    }

    var kind: Kind
    /// Litres for fuel, kWh for a charge; nil when the gauge didn't rise (energy used on the way hid it).
    var amount: Double?
    /// Dong.
    var cost: Double?
    var amountEstimated: Bool
    var costEstimated: Bool
    /// The estimate, for the editor to show and go back to.
    var estimatedAmount: Double?
    var price: Double?
    /// How the estimate was made, for the editor; nil uses the trip's own wording.
    var note: String? = nil
    /// A charge while parked after the trip, not one on the way.
    var after = false

    var unit: String { kind == .fuel ? "L" : "kWh" }
    var title: String { kind == .fuel ? "Refuelled" : after ? "Charged after" : "Charged" }
    var symbol: String { kind == .fuel ? "fuelpump.fill" : "bolt.fill" }

    /// "≈ 33.6 L · ≈ 711kđ"; nil when there is nothing to show.
    var summary: String? {
        var parts: [String] = []
        if let amount {
            parts.append((amountEstimated ? "≈ " : "") + amount.formatted(.number.precision(.fractionLength(1))) + " " + unit)
        }
        if let cost {
            parts.append((costEstimated ? "≈ " : "") + Money.kdong(cost))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Trip {
    /// The refuel and the charge on the way, if the car flagged either.
    func refills(_ settings: EnergySettings) -> [Refill] {
        [Refill.Kind.fuel, .charge].compactMap { refill($0, settings) }
    }

    func refill(_ kind: Refill.Kind, _ settings: EnergySettings) -> Refill? {
        let estimated: Double?
        let price: Double?
        switch kind {
        case .fuel:
            guard has(.refuelledDuringTrip) else { return nil }
            estimated = Self.rise(fuelStart, fuelEnd).map { $0 / 100 * settings.tankLitres }
            price = cost?.priceLitre
        case .charge:
            guard has(.chargedDuringTrip) else { return nil }
            estimated = Self.rise(socStart, socEnd).map { $0 / 100 * settings.batteryKwh }
            price = cost?.priceKwh
        }
        let edit = refills?[kind]
        let amount = edit?.amount ?? estimated
        let cost = edit?.cost ?? both(amount, price).map { $0 * $1 }
        return Refill(kind: kind, amount: amount, cost: cost,
                      amountEstimated: edit?.amount == nil, costEstimated: edit?.cost == nil,
                      estimatedAmount: estimated, price: price)
    }

    private static func rise(_ start: Double?, _ end: Double?) -> Double? {
        guard let start, let end, end > start else { return nil }
        return end - start
    }
}

/// A charge while the car stood between two trips: the battery was at least 5 points higher when
/// the next trip began than when the car stopped. `kwh` is the server's estimate of what the
/// charger delivered; `edit` is what someone said it really came to.
struct Charge: Codable, Identifiable, Equatable {
    var id: String
    /// When the car stopped before the charge.
    var parkedAt: Date
    /// When the car's charging flag came on, else when it stopped.
    var startAt: Date
    /// When the flag went off, else when the next trip began.
    var endAt: Date
    var odometerKm: Double
    var socStart: Double
    var socEnd: Double
    var chargingSeen: Bool
    var kwh: Double?
    var priceKwh: Double?
    var edit: TripRefills.Edit?
    var deletedAt: Date?

    var day: Date { Calendar.current.startOfDay(for: endAt) }

    func refill(_ settings: EnergySettings) -> Refill {
        let amount = edit?.amount ?? kwh
        let cost = edit?.cost ?? both(amount, priceKwh).map { $0 * $1 }
        let lost = Int(((1 - settings.chargeEfficiency) * 100).rounded())
        var note = "Leave a field empty to use the estimate: the battery rose from \(Int(socStart)) % to \(Int(socEnd)) % of \(settings.batteryKwh.formatted(.number.precision(.fractionLength(0...1)))) kWh, with \(lost) % more lost while charging"
        if let priceKwh { note += ", at \(Money.kdong(priceKwh, per: "kWh"))" }
        return Refill(kind: .charge, amount: amount, cost: cost,
                      amountEstimated: edit?.amount == nil, costEstimated: edit?.cost == nil,
                      estimatedAmount: kwh, price: priceKwh, note: note + ".", after: true)
    }

    /// "09:53–10:24".
    var timeRange: String {
        startAt.formatted(date: .omitted, time: .shortened) + "–" + endAt.formatted(date: .omitted, time: .shortened)
    }
}

private func both(_ a: Double?, _ b: Double?) -> (Double, Double)? {
    guard let a, let b else { return nil }
    return (a, b)
}

struct TripCost: Codable, Equatable {
    var total: Double
    var perKm: Double
    var priceKwh: Double?
    var priceLitre: Double?
    /// The fuel-price cycle the petrol price came from, e.g. "2026-11-03".
    var petrolCycle: String?
}

struct TripLocation: Codable, Equatable {
    var lat: Double
    var lon: Double
}

/// What a phone tells the server about its own ride (`POST /trips/events`).
struct PhoneEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case departure, arrival
    }

    var id = UUID()
    var kind: Kind
    var at: Date
    var lat: Double?
    var lon: Double?

    private enum CodingKeys: String, CodingKey {
        case kind, at, lat, lon
    }
}

struct PhoneEventsBody: Encodable {
    var phoneId: String
    var phoneName: String
    var events: [PhoneEvent]
}

/// `GET|PUT /settings`: prices and car capacities shared by every phone.
struct EnergySettings: Codable, Equatable {
    enum Source: String, Codable {
        case model, measured, manual

        var label: String {
            switch self {
            case .model: "from the model"
            case .measured: "measured"
            case .manual: "manual"
            }
        }
    }

    var priceKwh: Double?
    var petrolOverrideVndPerLitre: Double?
    var batteryKwh: Double = 18.3
    var tankLitres: Double = 60
    var batterySource: Source = .model
    var tankSource: Source = .model
    var notifyOnTrip: Bool = false
    /// Share of the charger's kWh that reaches the battery.
    var chargeEfficiency: Double = 0.9

    init() {}

    /// Tolerant of a server that leaves fields out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        priceKwh = try c.decodeIfPresent(Double.self, forKey: .priceKwh)
        petrolOverrideVndPerLitre = try c.decodeIfPresent(Double.self, forKey: .petrolOverrideVndPerLitre)
        batteryKwh = try c.decodeIfPresent(Double.self, forKey: .batteryKwh) ?? 18.3
        tankLitres = try c.decodeIfPresent(Double.self, forKey: .tankLitres) ?? 60
        batterySource = try c.decodeIfPresent(Source.self, forKey: .batterySource) ?? .model
        tankSource = try c.decodeIfPresent(Source.self, forKey: .tankSource) ?? .model
        notifyOnTrip = try c.decodeIfPresent(Bool.self, forKey: .notifyOnTrip) ?? false
        chargeEfficiency = try c.decodeIfPresent(Double.self, forKey: .chargeEfficiency) ?? 0.9
    }
}

/// `GET /prices`: the petrol price the server fetched, and hints for the settings screen.
struct Prices: Codable, Equatable {
    struct Petrol: Codable, Equatable {
        var product: String?
        /// Petrolimex price zone, 1 or 2 (the server sends a number).
        var zone: Int?
        var vndPerLitre: Double
        var source: String?
        /// The state's price cycle this came from, e.g. "2026-11-03".
        var cycle: String?
        var fetchedAt: Date?
        var stale: Bool?
    }

    struct ElectricityHint: Codable, Equatable {
        var tariffFrom: String?
        var tiersVndPerKwh: [Double]?
    }

    struct CapacityHint: Codable, Equatable {
        var batteryKwh: Double?
        var tankLitres: Double?
        var model: String?
    }

    var petrol: Petrol?
    var electricityHint: ElectricityHint?
    var capacityHint: CapacityHint?
}

struct Phone: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var lastSeen: Date?
}

/// Who the server thinks is driving (`GET /phones`, `POST /lease`).
struct Leader: Codable, Equatable {
    var phoneId: String
    var name: String?
    var until: Date?
}

struct PhonesResponse: Codable, Equatable {
    var phones: [Phone]
    var leader: Leader?
}

struct LeaseRequest: Encodable {
    var phoneId: String
    var phoneName: String
    var kind = "car"
    var ttlSeconds = 120
}

struct LeaseResponse: Codable, Equatable {
    var granted: Bool
    var leader: Leader?
}

struct TripsResponse: Codable {
    var trips: [Trip]
    var charges: [Charge]? = nil
    var openTrip: Trip?
    var settings: EnergySettings?
    var serverTime: Date?
}

/// Vietnamese dong, always in thousands: "758kđ", "47kđ", "1.8kđ/km".
enum Money {
    /// One decimal under 10k, none above; a price per `unit` ("/km", "/L", "/kWh") always keeps one.
    static func kdong(_ vnd: Double, per unit: String? = nil) -> String {
        thousands(vnd, decimal: abs(vnd) < 10_000 || unit != nil) + "kđ" + (unit.map { "/" + $0 } ?? "")
    }

    /// Just the number in thousands, for views that style the "kđ" themselves.
    static func thousands(_ vnd: Double, decimal: Bool) -> String {
        (vnd / 1000).formatted(.number.precision(.fractionLength(decimal ? 1 : 0)))
    }
}

/// A Monday-to-Sunday week, for the chart and the trip list.
struct Week: Hashable, Comparable, Identifiable {
    let start: Date

    var id: Date { start }
    var end: Date { Calendar.current.date(byAdding: .day, value: 7, to: start)! }
    /// Monday to Sunday.
    var days: [Date] { (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! } }

    init(containing date: Date) {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        start = calendar.date(from: components)!
    }

    private init(start: Date) { self.start = start }

    var previous: Week { Week(start: Calendar.current.date(byAdding: .day, value: -7, to: start)!) }
    var next: Week { Week(start: end) }

    static func < (lhs: Week, rhs: Week) -> Bool { lhs.start < rhs.start }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// "This week", "Last week" or "27 Oct – 2 Nov".
    var title: String {
        let now = Week(containing: Date())
        if self == now { return "This week" }
        if self == now.previous { return "Last week" }
        return range
    }

    /// "3 – 9 Nov" or "27 Oct – 2 Nov".
    var range: String {
        let last = Calendar.current.date(byAdding: .day, value: 6, to: start)!
        let sameMonth = Calendar.current.isDate(start, equalTo: last, toGranularity: .month)
        let first = sameMonth ? start.formatted(.dateTime.day()) : start.formatted(.dateTime.day().month(.abbreviated))
        return "\(first) – \(last.formatted(.dateTime.day().month(.abbreviated)))"
    }
}

/// Sums over a set of trips: the card, the week tiles and the chart.
struct TripTotals: Equatable {
    var km = 0.0
    var kwh = 0.0
    var litres = 0.0
    var evKm = 0.0
    var cost: Double?

    init(_ trips: [Trip]) {
        var costed = 0.0
        var anyCost = false
        for trip in trips {
            km += trip.km
            kwh += trip.kwh
            litres += trip.litres
            evKm += trip.evKm
            if let cost = trip.cost {
                costed += cost.total
                anyCost = true
            }
        }
        cost = anyCost ? costed : nil
    }

    var electricShare: Double { km > 0 ? min(max(evKm / km, 0), 1) : 0 }
    var costPerKm: Double? { cost.flatMap { km > 0 ? $0 / km : nil } }
}

/// One bar of the week chart.
struct DayKm: Identifiable {
    var day: Date
    var evKm: Double
    var petrolKm: Double
    /// A charge between trips or on the way, and a refuel, that day: marked above the bar.
    var charged = false
    var refuelled = false

    var id: Date { day }
}

/// A row of the trip log: a trip, or a charge between two trips.
enum LogEntry: Identifiable {
    case trip(Trip)
    case charge(Charge)

    var id: String {
        switch self {
        case .trip(let trip): "trip-" + trip.id
        case .charge(let charge): "charge-" + charge.id
        }
    }

    var day: Date {
        switch self {
        case .trip(let trip): trip.day
        case .charge(let charge): charge.day
        }
    }

    var sortDate: Date {
        switch self {
        case .trip(let trip): trip.endAt ?? trip.startAt
        case .charge(let charge): charge.endAt
        }
    }
}

enum TripMath {
    /// Closed trips in a calendar month.
    static func trips(_ trips: [Trip], inMonthOf date: Date) -> [Trip] {
        trips.filter { !$0.isOpen && Calendar.current.isDate($0.day, equalTo: date, toGranularity: .month) }
    }

    static func trips(_ trips: [Trip], in week: Week) -> [Trip] {
        trips.filter { !$0.isOpen && week.contains($0.day) }
    }

    /// Kilometres per day of the week, Monday first; days without trips are zero.
    static func dailyKm(_ trips: [Trip], _ charges: [Charge] = [], in week: Week) -> [DayKm] {
        week.days.map { day in
            let same = trips.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
            let charged = same.contains { $0.has(.chargedDuringTrip) }
                || charges.contains { Calendar.current.isDate($0.day, inSameDayAs: day) }
            return DayKm(day: day, evKm: same.reduce(0) { $0 + $1.evKm }, petrolKm: same.reduce(0) { $0 + $1.petrolKm },
                         charged: charged, refuelled: same.contains { $0.has(.refuelledDuringTrip) })
        }
    }

    static func charges(_ charges: [Charge], in week: Week) -> [Charge] {
        charges.filter { week.contains($0.day) }
    }

    /// Newest day first, each day's trips and charges newest first.
    static func byDay(_ trips: [Trip], _ charges: [Charge] = []) -> [(day: Date, entries: [LogEntry])] {
        let entries = trips.map(LogEntry.trip) + charges.map(LogEntry.charge)
        let groups = Dictionary(grouping: entries, by: \.day)
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { $0.sortDate > $1.sortDate })
        }
    }

    /// Every week from the oldest trip to this week, oldest first.
    static func weeks(_ trips: [Trip]) -> [Week] {
        let now = Week(containing: Date())
        guard let oldest = trips.map(\.day).min() else { return [now] }
        var week = Week(containing: oldest)
        var weeks: [Week] = []
        while week <= now {
            weeks.append(week)
            week = week.next
        }
        return weeks
    }

    /// "Today · Thu 6 Nov", "Yesterday · Wed 5 Nov", "Mon 3 Nov".
    static func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if Calendar.current.isDateInToday(day) { return "Today · \(date)" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday · \(date)" }
        return date
    }

    /// "Today 17:50", "Yesterday 08:12", "Mon 3 Nov 19:05".
    static func tripTitle(_ trip: Trip) -> String {
        let time = trip.startAt.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(trip.startAt) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(trip.startAt) { return "Yesterday \(time)" }
        return "\(trip.startAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(time)"
    }

    /// "46 min", "1 h 12 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// This phone, as the server knows it: a stable id in the Keychain, a name you can change.
enum PhoneIdentity {
    private static let account = "phone.id"
    private static let nameKey = "phone.name"
    private static let defaults = UserDefaults(suiteName: AppConfig.appGroup) ?? .standard

    static var id: String {
        if let existing = readKeychain() { return existing }
        let fresh = UUID().uuidString
        writeKeychain(fresh)
        return fresh
    }

    static var name: String {
        get {
            if let saved = defaults.string(forKey: nameKey), !saved.isEmpty { return saved }
            return UIDevice.current.name
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: nameKey) }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.bundleID + ".phone",
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) {
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
