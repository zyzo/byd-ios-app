import Foundation

/// Demo mode: sample data instead of a real car, for screenshots and trying the UI.
/// Turn it on with the launch argument `-demo YES` (Xcode › Scheme › Run › Arguments).
@MainActor
enum DemoCar {
    static var status = CarStatus.sample

    static let log = [
        "Reconnecting to the known car",
        "Connected; discovering services",
        "→ wake",
        "→ random exchange (key #0)",
        "← random: keyState=1 crc=1",
        "→ authenticate",
        "← auth result 1",
        "Bluetooth ready",
    ]

    static func apply(_ command: CarCommand) {
        status.apply(command)
    }

    /// A pretend drive: moves the odometer, battery and fuel, and logs the trip.
    static func drive() {
        let km = Double(Int.random(in: 6...24))
        let evKm = min(km, Double(Int.random(in: 4...18)))
        let kwh = (evKm * 0.17 * 10).rounded() / 10
        let litres = ((km - evKm) * 0.055 * 10).rounded() / 10
        let socDrop = kwh / DemoTrips.settings.batteryKwh * 100
        let fuelDrop = litres / DemoTrips.settings.tankLitres * 100
        let start = status
        status.odometerKm = (start.odometerKm ?? 0) + km
        status.batteryPercent = max(0, (start.batteryPercent ?? 0) - socDrop.rounded())
        status.fuelPercent = max(0, (start.fuelPercent ?? 0) - fuelDrop.rounded())
        status.rangeElectricKm = max(0, (start.rangeElectricKm ?? 0) - evKm)
        status.rangeFuelKm = max(0, (start.rangeFuelKm ?? 0) - (km - evKm) * 18)
        status.rangeTotalKm = (status.rangeElectricKm ?? 0) + (status.rangeFuelKm ?? 0)
        status.updatedAt = Date()
        status.receivedAt = Date()
        let minutes = Int(km * 1.8) + 4
        DemoTrips.append(DemoTrips.trip(
            id: "demo-\(UUID().uuidString.prefix(8))",
            start: Date().addingTimeInterval(-Double(minutes) * 60), minutes: minutes,
            km: km, kwh: kwh, litres: litres,
            odoStart: start.odometerKm ?? 0, socStart: start.batteryPercent ?? 0, fuelStart: start.fuelPercent ?? 0,
            phone: DemoTrips.thisPhone
        ))
    }
}

/// Sample trip log for demo mode: five weeks of mixed driving on two phones.
@MainActor
enum DemoTrips {
    static let thisPhone = Phone(id: PhoneIdentity.id, name: PhoneIdentity.name, lastSeen: Date())
    static let otherPhone = Phone(id: "demo-other-phone", name: "Hieu's iPhone", lastSeen: Date().addingTimeInterval(-3 * 3600))

    static let prices = Prices(
        petrol: .init(product: "E10 RON 95-III", zone: "Vùng 1", vndPerLitre: 23_230, source: "Petrolimex via webgia", cycle: "2026-11-03",
                      fetchedAt: Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date().addingTimeInterval(-86_400)), stale: false),
        electricityHint: .init(tariffFrom: "2026-11-01", tiersVndPerKwh: [1_984, 2_050, 2_380, 2_998, 3_350, 3_460]),
        capacityHint: .init(batteryKwh: 18.3, tankLitres: 60, model: "Sealion 6 DM-i")
    )

    static var settings: EnergySettings = {
        var s = EnergySettings()
        s.priceKwh = 3_732
        return s
    }()

    private static let evRate = 0.17

    private(set) static var trips: [Trip] = seed()
    private static var deleted: Set<String> = []

    static func response() async -> TripsResponse {
        try? await Task.sleep(for: .milliseconds(300))
        return TripsResponse(trips: trips, openTrip: nil, settings: settings, serverTime: Date())
    }

    static func delete(_ id: String) {
        deleted.insert(id)
        trips.removeAll { $0.id == id }
    }

    static func update(_ new: EnergySettings) {
        settings = new
    }

    static func phones() -> PhonesResponse {
        PhonesResponse(phones: [thisPhone, otherPhone], leader: nil)
    }

    static func append(_ trip: Trip) {
        trips.insert(trip, at: 0)
    }

    /// A closed trip; cost at the sample prices, electric share from the kWh.
    static func trip(id: String, start: Date, minutes: Int, km: Double, kwh: Double, litres: Double,
                     odoStart: Double, socStart: Double, fuelStart: Double,
                     phone: Phone?, flags: [Trip.Flag] = [], source: String = "car") -> Trip {
        let tooShort = flags.contains(.tooShortToMeasure)
        let evKm = tooShort ? 0 : (litres == 0 ? km : min(km, kwh / evRate))
        let petrolKm = tooShort ? 0 : km - evKm
        let socEnd = max(0, socStart - (kwh / settings.batteryKwh * 100).rounded())
        let fuelEnd = max(0, fuelStart - (litres / settings.tankLitres * 100).rounded())
        var cost: TripCost?
        if !tooShort, let priceKwh = settings.priceKwh, let petrol = prices.petrol {
            let total = kwh * priceKwh + litres * petrol.vndPerLitre
            cost = TripCost(total: total, perKm: km > 0 ? total / km : 0, priceKwh: priceKwh, priceLitre: petrol.vndPerLitre, petrolCycle: petrol.cycle)
        }
        return Trip(
            id: id, startAt: start, endAt: start.addingTimeInterval(Double(minutes) * 60), km: km,
            odoStart: odoStart, odoEnd: odoStart + km, socStart: socStart, socEnd: socEnd,
            fuelStart: fuelStart, fuelEnd: fuelEnd,
            kwh: tooShort ? 0 : kwh, litres: tooShort ? 0 : litres, evKm: evKm, petrolKm: petrolKm,
            electricShare: km > 0 ? evKm / km : 0, cost: cost,
            phoneId: phone?.id, phoneName: phone?.name,
            startLocation: phone == nil ? nil : TripLocation(lat: 10.7769, lon: 106.7009),
            endLocation: phone == nil ? nil : TripLocation(lat: 10.8014, lon: 106.6539),
            flags: flags.map(\.rawValue), source: source, deletedAt: nil
        )
    }

    private static func seed() -> [Trip] {
        let calendar = Calendar.current
        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        // Newest first; odometer counts down from the sample car's reading.
        let rows: [(days: Int, h: Int, m: Int, min: Int, km: Double, kwh: Double, l: Double, phone: Phone?, flags: [Trip.Flag])] = [
            (0, 8, 12, 25, 14, 2.3, 0, thisPhone, []),
            (1, 19, 5, 18, 9, 1.5, 0, thisPhone, []),
            (1, 7, 58, 5, 2, 0, 0, thisPhone, [.tooShortToMeasure]),
            (2, 17, 50, 46, 38, 2.6, 1.8, nil, [.chargedDuringTrip]),
            (3, 8, 5, 24, 13, 2.2, 0, thisPhone, []),
            (6, 10, 30, 95, 86, 3.1, 4.6, otherPhone, []),
            (8, 18, 20, 31, 21, 2.4, 0.4, thisPhone, []),
            (12, 9, 15, 22, 12, 2.0, 0, otherPhone, []),
            (15, 7, 40, 140, 132, 2.9, 7.5, thisPhone, [.refuelledDuringTrip]),
            (20, 19, 30, 27, 17, 2.7, 0, thisPhone, []),
            (26, 8, 10, 35, 24, 1.9, 1.1, nil, [.coarse]),
            (33, 16, 0, 58, 44, 2.8, 2.2, otherPhone, []),
        ]
        var odo = (CarStatus.sample.odometerKm ?? 12_480) - 14
        var soc = 78.0
        var fuel = 61.0
        var trips: [Trip] = []
        for (i, r) in rows.enumerated() {
            let kwh = r.flags.contains(.tooShortToMeasure) ? 0 : r.kwh
            let litres = r.flags.contains(.tooShortToMeasure) ? 0 : r.l
            let socStart = min(100, soc + (kwh / settings.batteryKwh * 100).rounded() + (r.flags.contains(.chargedDuringTrip) ? -20 : 0))
            let fuelStart = min(100, fuel + (litres / settings.tankLitres * 100).rounded() + (r.flags.contains(.refuelledDuringTrip) ? -30 : 0))
            trips.append(trip(
                id: "demo-\(i)", start: at(daysAgo: r.days, r.h, r.m), minutes: r.min, km: r.km, kwh: kwh, litres: litres,
                odoStart: odo, socStart: socStart, fuelStart: fuelStart, phone: r.phone, flags: r.flags,
                source: r.flags.contains(.coarse) ? "coarse" : "car"
            ))
            odo -= r.km
            soc = socStart < 30 ? 82 : socStart
            fuel = fuelStart
        }
        return trips
    }
}
