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

    func has(_ flag: Flag) -> Bool { flags.contains(flag.rawValue) }
    var withoutPhone: Bool { phoneId == nil }
    var tooShort: Bool { has(.tooShortToMeasure) }
    var isOpen: Bool { endAt == nil }
    var duration: TimeInterval? { endAt.map { $0.timeIntervalSince(startAt) } }
    /// Trips are grouped by when they ended; an open trip by when it started.
    var day: Date { Calendar.current.startOfDay(for: endAt ?? startAt) }
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
    }
}

/// `GET /prices`: the petrol price the server fetched, and hints for the settings screen.
struct Prices: Codable, Equatable {
    struct Petrol: Codable, Equatable {
        var product: String?
        var zone: String?
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

    var id: Date { day }
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
    static func dailyKm(_ trips: [Trip], in week: Week) -> [DayKm] {
        week.days.map { day in
            let same = trips.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
            return DayKm(day: day, evKm: same.reduce(0) { $0 + $1.evKm }, petrolKm: same.reduce(0) { $0 + $1.petrolKm })
        }
    }

    /// Newest day first, each day's trips newest first.
    static func byDay(_ trips: [Trip]) -> [(day: Date, trips: [Trip])] {
        let groups = Dictionary(grouping: trips, by: \.day)
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { ($0.endAt ?? $0.startAt) > ($1.endAt ?? $1.startAt) })
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
