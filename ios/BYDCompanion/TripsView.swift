import Charts
import SwiftUI

/// Home screen card: this month's distance, energy and cost, with the electric share.
struct TripsCard: View {
    let store: TripStore
    var drivingSince: Date?
    let action: () -> Void

    private var month: [Trip] { TripMath.trips(store.trips, inMonthOf: Date()) }

    var body: some View {
        Button(action: action) {
            Group {
                if store.trips.isEmpty {
                    empty
                } else {
                    summary(TripTotals(month))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Trips this month")
        .accessibilityHint("Shows the trip log")
    }

    private var empty: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trips").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("No logged trip yet").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            chevron
        }
    }

    private func summary(_ totals: TripTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trips this month").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                if let drivingSince {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(Theme.text)
                        Text("Driving since \(drivingSince.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xC9D1D9))
                    }
                } else {
                    chevron
                }
            }
            HStack(alignment: .firstTextBaseline) {
                bigNumber(totals.km.formatted(.number.precision(.fractionLength(0))), "km")
                Spacer()
                energy(totals.kwh, totals.litres)
            }
            ShareBar(share: totals.electricShare, height: 6)
            if let cost = totals.cost, let perKm = totals.costPerKm {
                Text("≈ \(Money.kdong(cost)) · \(Money.kdong(perKm, per: "km"))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(totals.km.rounded())) km, \(Int((totals.electricShare * 100).rounded())) percent electric")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.muted)
    }
}

/// "412 km", "48 kWh · 7.8 L": a big number with its unit in muted 13 pt.
private func bigNumber(_ value: String, _ unit: String, size: CGFloat = 22) -> Text {
    Text(value).font(.system(size: size, weight: .semibold)).foregroundColor(Theme.text)
        + Text(" " + unit).font(.system(size: 13)).foregroundColor(Theme.muted)
}

private func energy(_ kwh: Double, _ litres: Double, size: CGFloat = 22) -> Text {
    var parts: [Text] = []
    if kwh > 0 || litres == 0 { parts.append(bigNumber(kwh.formatted(.number.precision(.fractionLength(kwh < 10 ? 1 : 0))), "kWh", size: size)) }
    if litres > 0 { parts.append(bigNumber(litres.formatted(.number.precision(.fractionLength(1))), "L", size: size)) }
    return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ").font(.system(size: size, weight: .semibold)).foregroundColor(Theme.text) + $1 }
}

/// The range bar's capsule: electric in accent over petrol in `Theme.fuel`.
struct ShareBar: View {
    let share: Double
    var height: CGFloat = 8
    /// Nothing measured: a flat border-coloured line.
    var empty = false

    var body: some View {
        GeometryReader { geo in
            if empty {
                Rectangle().fill(Theme.cardBorder)
            } else {
                let electric = min(max(share, 0), 1)
                HStack(spacing: 2) {
                    if electric > 0.005 {
                        Rectangle().fill(Theme.accent).frame(width: geo.size.width * electric)
                    }
                    if electric < 0.995 {
                        Rectangle().fill(Theme.fuel)
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// The trip log: a week's chart and totals, then its trips by day.
struct TripsSheet: View {
    let store: TripStore
    let logger: TripLogger
    @Environment(\.dismiss) private var dismiss
    @State private var week = Week(containing: Date())
    @State private var pendingDelete: Trip?
    @State private var detent: PresentationDetent = .large

    private var weeks: [Week] { TripMath.weeks(store.trips) }
    private var weekTrips: [Trip] { TripMath.trips(store.trips, in: week) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TabView(selection: $week) {
                        ForEach(weeks) { w in
                            WeekCard(week: w, trips: TripMath.trips(store.trips, in: w), previous: previous, next: next)
                                .tag(w)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 332)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Theme.card)
                }

                if let open = store.openTrip ?? openPlaceholder {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Theme.text)
                            Text("Driving since \(open.startAt.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text("waiting for the car's report").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        .listRowBackground(Theme.card)
                    }
                }

                ForEach(TripMath.byDay(weekTrips), id: \.day) { group in
                    Section {
                        ForEach(group.trips) { trip in
                            NavigationLink(value: trip.id) { TripRow(trip: trip) }
                                .listRowBackground(Theme.card)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = trip } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    } header: {
                        Text(TripMath.dayTitle(group.day)).font(.system(size: 13)).foregroundStyle(Theme.muted).textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let trip = store.trips.first(where: { $0.id == id }) {
                    TripDetail(trip: trip, store: store)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { TripSettingsView(store: store, logger: logger) } label: {
                        Image(systemName: "gearshape").accessibilityLabel("Trip settings")
                    }
                }
            }
            .confirmationDialog("Delete this trip?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete trip", role: .destructive) {
                    if let trip = pendingDelete { Task { await store.delete(trip) } }
                    pendingDelete = nil
                }
            }
            .refreshable { await logger.sync() }
            .task { await logger.sync() }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    /// In demo mode a simulated trip shows as driving while it runs.
    private var openPlaceholder: Trip? {
        guard let since = logger.drivingSince else { return nil }
        return Trip(id: "open", startAt: since, endAt: nil, km: 0, kwh: 0, litres: 0, evKm: 0, petrolKm: 0, electricShare: 0, flags: [], source: "car")
    }

    private func previous() {
        guard let index = weeks.firstIndex(of: week), index > 0 else { return }
        withAnimation { week = weeks[index - 1] }
    }

    private func next() {
        guard let index = weeks.firstIndex(of: week), index + 1 < weeks.count else { return }
        withAnimation { week = weeks[index + 1] }
    }
}

/// One page of the week pager: arrows, the km-per-day chart and the week's totals.
struct WeekCard: View {
    let week: Week
    let trips: [Trip]
    let previous: () -> Void
    let next: () -> Void

    private var totals: TripTotals { TripTotals(trips) }
    private var days: [DayKm] { TripMath.dailyKm(trips, in: week) }
    private var isCurrent: Bool { week == Week(containing: Date()) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                arrow("chevron.left", "Previous week", action: previous)
                Spacer()
                VStack(spacing: 2) {
                    Text(week.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    if week.title != week.range {
                        Text(week.range).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                arrow("chevron.right", "Next week", action: next).opacity(isCurrent ? 0.35 : 1).disabled(isCurrent)
            }

            chart

            Divider().overlay(Theme.cardBorder)

            HStack(alignment: .top, spacing: 8) {
                tile(totals.km.formatted(.number.precision(.fractionLength(0))), totals.km > 0 ? "km · \(Int((totals.electricShare * 100).rounded())) % electric" : "km")
                tile(totals.kwh.formatted(.number.precision(.fractionLength(totals.kwh < 10 ? 1 : 0))), "kWh")
                tile(totals.litres.formatted(.number.precision(.fractionLength(1))), "litres")
            }
            HStack {
                if let cost = totals.cost, let perKm = totals.costPerKm {
                    Text("≈ \(Money.kdong(cost)) · \(Money.kdong(perKm, per: "km"))")
                } else if !trips.isEmpty {
                    Text("Cost unknown: set the prices behind the gear")
                }
                Spacer()
            }
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }

    private static func label(_ day: Date) -> String { day.formatted(.dateTime.weekday(.abbreviated)) }

    private var chart: some View {
        let todayLabel = Calendar.current.isDate(Date(), equalTo: week.start, toGranularity: .weekOfYear) || week.contains(Date())
            ? Self.label(Date()) : ""
        return Chart(days) { day in
            BarMark(x: .value("Day", Self.label(day.day)), y: .value("Electric km", day.evKm))
                .foregroundStyle(Theme.accent)
            BarMark(x: .value("Day", Self.label(day.day)), y: .value("Petrol km", day.petrolKm))
                .foregroundStyle(Theme.fuel)
        }
        .chartXAxis {
            AxisMarks(values: days.map { Self.label($0.day) }) { value in
                if let label = value.as(String.self) {
                    let isToday = label == todayLabel
                    AxisValueLabel(centered: true) {
                        Text(label)
                            .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? Theme.text : Theme.muted)
                    }
                }
            }
        }
        .chartXScale(domain: days.map { Self.label($0.day) })
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 140)
        .accessibilityLabel("Kilometres per day, electric in teal and petrol in grey")
    }

    private func arrow(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0xC9D1D9))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(RaisedButtonStyle(cornerRadius: 10))
        .accessibilityLabel(label)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(trip.startAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("· \(Int(trip.km.rounded())) km").font(.system(size: 15)).foregroundStyle(Theme.muted)
                if trip.withoutPhone {
                    Text("·").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .accessibilityLabel("Driven without the phone")
                }
                Spacer()
                if !trip.tooShort {
                    energy(trip.kwh, trip.litres, size: 15)
                }
            }
            ShareBar(share: trip.electricShare, height: 4, empty: trip.tooShort)
            if !trip.tooShort, let cost = trip.cost {
                Text("≈ " + Money.kdong(cost.total)).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct TripDetail: View {
    let trip: Trip
    let store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summary
                table("From the car") {
                    header3("", "Left", "Arrived")
                    row3("Time", trip.startAt.formatted(date: .omitted, time: .shortened), trip.endAt?.formatted(date: .omitted, time: .shortened) ?? "–")
                    row3("Odometer", km(trip.odoStart), km(trip.odoEnd))
                    row3("Battery", percent(trip.socStart), percent(trip.socEnd))
                    row3("Fuel", percent(trip.fuelStart), percent(trip.fuelEnd), last: true)
                }
                if let cost = trip.cost {
                    costTable(cost)
                }
                Button {
                    confirmingDelete = true
                } label: {
                    Text("Delete trip")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(TripMath.tripTitle(trip)).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(trip.phoneName ?? (trip.withoutPhone ? "Without a phone" : "Another phone"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .confirmationDialog("Delete this trip?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete trip", role: .destructive) {
                Task { await store.delete(trip) }
                dismiss()
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                tile(trip.km.formatted(.number.precision(.fractionLength(0))), trip.duration.map { "km · \(TripMath.duration($0))" } ?? "km")
                tile(trip.kwh.formatted(.number.precision(.fractionLength(1))), "kWh")
                tile(trip.litres.formatted(.number.precision(.fractionLength(1))), "litres")
                if let cost = trip.cost {
                    tile(Money.kdong(cost.total), "cost · \(Money.kdong(cost.perKm, per: "km"))", unitStyled: true)
                } else {
                    tile("–", "cost")
                }
            }
            VStack(spacing: 8) {
                ShareBar(share: trip.electricShare, empty: trip.tooShort)
                HStack {
                    legend("Electric", trip.evKm)
                    Spacer()
                    legend("Petrol", trip.petrolKm)
                }
            }
            if !badges.isEmpty {
                Divider().overlay(Theme.cardBorder)
                HStack(spacing: 6) {
                    ForEach(badges, id: \.text) { badge in
                        HStack(spacing: 5) {
                            if let symbol = badge.symbol {
                                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            if badge.amber {
                                Circle().fill(Theme.warning).frame(width: 7, height: 7)
                            }
                            Text(badge.text).font(.system(size: 12)).foregroundStyle(Color(hex: 0xC9D1D9))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.background))
                        .overlay(Capsule().strokeBorder(Theme.cardBorder))
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private struct Badge {
        var text: String
        var symbol: String?
        var amber = false
    }

    private var badges: [Badge] {
        var list: [Badge] = []
        if trip.withoutPhone { list.append(Badge(text: "Without phone", symbol: "iphone.slash")) }
        if trip.has(.chargedDuringTrip) { list.append(Badge(text: "Charged on the way", amber: true)) }
        if trip.has(.refuelledDuringTrip) { list.append(Badge(text: "Refuelled", amber: true)) }
        if trip.tooShort { list.append(Badge(text: "Too short to measure")) }
        if trip.has(.coarse) { list.append(Badge(text: "From the odometer only")) }
        return list
    }

    private func costTable(_ cost: TripCost) -> some View {
        table("Cost, at the prices of that day") {
            row2("Per km", Money.kdong(cost.perKm, per: "km"), bold: true)
            if let price = cost.priceKwh, trip.kwh > 0 {
                row2("Electricity", Money.kdong(trip.kwh * price), detail: "· \(trip.kwh.formatted(.number.precision(.fractionLength(1)))) kWh × \(Money.thousands(price, decimal: true))kđ")
            }
            if let price = cost.priceLitre, trip.litres > 0 {
                row2("Petrol", Money.kdong(trip.litres * price), detail: "· \(trip.litres.formatted(.number.precision(.fractionLength(1)))) L × \(Money.thousands(price, decimal: true))kđ")
            }
            HStack {
                Text(priceFooter(cost))
                Spacer()
                Text(Money.kdong(cost.total))
            }
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private func priceFooter(_ cost: TripCost) -> String {
        var parts: [String] = []
        if cost.priceKwh != nil, trip.kwh > 0 { parts.append("Electricity as set") }
        if cost.priceLitre != nil, trip.litres > 0 {
            var petrol = "Petrol E10 RON 95-III"
            if let cycle = cost.petrolCycle { petrol += ", " + Self.cycleLabel(cycle) }
            parts.append(petrol)
        }
        return parts.joined(separator: " · ")
    }

    /// "2026-11-03" → "3 Nov".
    static func cycleLabel(_ cycle: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: cycle) else { return cycle }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func table<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.horizontal, 16)
            VStack(spacing: 0, content: content)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardBorder))
        }
    }

    private func header3(_ a: String, _ b: String, _ c: String) -> some View {
        HStack {
            Text(a).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(width: 90, alignment: .trailing)
            Text(c).frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.muted)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.cardBorder) }
    }

    private func row3(_ label: String, _ left: String, _ right: String, last: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
            Text(left).foregroundStyle(Theme.text).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(right).foregroundStyle(Theme.text).monospacedDigit().frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { if !last { Divider().overlay(Theme.cardBorder) } }
        .accessibilityElement(children: .combine)
    }

    private func row2(_ label: String, _ value: String, detail: String? = nil, bold: Bool = false) -> some View {
        HStack {
            (Text(label).foregroundColor(Theme.muted) + Text(detail.map { " " + $0 } ?? "").font(.system(size: 12)).foregroundColor(Theme.muted))
            Spacer()
            Text(value).fontWeight(bold ? .semibold : .regular).foregroundStyle(Theme.text).monospacedDigit()
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.cardBorder) }
        .accessibilityElement(children: .combine)
    }

    private func tile(_ value: String, _ label: String, unitStyled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if unitStyled, value.hasSuffix("kđ") {
                (Text(value.dropLast(2)).font(.system(size: 24, weight: .semibold)).foregroundColor(Theme.text)
                    + Text("kđ").font(.system(size: 14)).foregroundColor(Theme.muted))
            } else {
                Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.75)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ label: String, _ km: Double) -> some View {
        (Text(label + " ").foregroundColor(Theme.muted)
            + Text(trip.tooShort ? "–" : "≈ \(Int(km.rounded())) km").fontWeight(.semibold).foregroundColor(Theme.text))
            .font(.system(size: 13))
    }

    private func km(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "–"
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) %" } ?? "–"
    }
}

/// Prices, car capacities, this phone's name and notifications, behind the gear.
struct TripSettingsView: View {
    let store: TripStore
    let logger: TripLogger
    @State private var draft = EnergySettings()
    @State private var phoneName = ""
    @State private var electricity = ""
    @State private var battery = ""
    @State private var tank = ""
    @State private var petrolOverride = ""
    @State private var editingPetrol = false
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Electricity")
                        Spacer()
                        TextField("3.7", text: $electricity)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.raisedBorder))
                            .onSubmit(commit)
                            .accessibilityLabel("Electricity price in thousand dong per kWh")
                        Text("kđ/kWh").font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                    }
                    Text(electricityHint).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Button {
                    petrolOverride = draft.petrolOverrideVndPerLitre.map { ($0 / 1000).formatted(.number.precision(.fractionLength(1))) } ?? ""
                    editingPetrol = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Petrol").foregroundStyle(Theme.text)
                                if draft.petrolOverrideVndPerLitre != nil {
                                    Text("manual").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.6)))
                                }
                            }
                            Text(petrolHint).font(.system(size: 12)).foregroundStyle(petrolStale ? Theme.warning : Theme.muted)
                        }
                        Spacer()
                        if let price = draft.petrolOverrideVndPerLitre ?? store.prices?.petrol?.vndPerLitre {
                            (Text(Money.thousands(price, decimal: true)).fontWeight(.semibold).foregroundColor(Theme.text)
                                + Text("kđ/L").font(.system(size: 13)).foregroundColor(Theme.muted))
                        } else {
                            Text("Set").foregroundStyle(Theme.muted)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                }
            } header: {
                Text("Prices, for the cost estimate")
            } footer: {
                Text("Petrol is fetched by the server from public Vietnamese sources. Each trip keeps the prices of its day.")
            }
            .listRowBackground(Theme.card)

            Section("Your car") {
                capacity("Battery (usable)", $battery, unit: "kWh", source: draft.batterySource, placeholder: "18.3")
                capacity("Fuel tank", $tank, unit: "L", source: draft.tankSource, placeholder: "60")
            }
            .listRowBackground(Theme.card)

            Section {
                HStack {
                    Text("Name")
                    TextField("This phone", text: $phoneName)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commit)
                }
            } header: {
                Text("This phone")
            } footer: {
                Text("Shown on trips this phone was in the car for. Other phones that share the car: \(otherPhones).")
            }
            .listRowBackground(Theme.card)

            Section("Notifications") {
                Toggle("Tell me when a trip is logged", isOn: $draft.notifyOnTrip)
                    .tint(Theme.accent)
                    .onChange(of: draft.notifyOnTrip) { _, on in
                        if on { CarNotifications.requestQuietPermission() }
                        commit()
                    }
            }
            .listRowBackground(Theme.card)

            if AppConfig.demo {
                Section {
                    Button(logger.simulating ? "Driving…" : "Simulate a trip") {
                        Task { await logger.simulateTrip() }
                    }
                    .disabled(logger.simulating)
                } footer: {
                    Text("Demo mode: drives the pretend car a few kilometres and logs the trip.")
                }
                .listRowBackground(Theme.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Petrol price", isPresented: $editingPetrol) {
            TextField("kđ per litre", text: $petrolOverride).keyboardType(.decimalPad)
            Button("Use my price") {
                draft.petrolOverrideVndPerLitre = Self.number(petrolOverride).map { $0 * 1000 }
                commit()
            }
            if draft.petrolOverrideVndPerLitre != nil {
                Button("Use the fetched price") {
                    draft.petrolOverrideVndPerLitre = nil
                    commit()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In thousand dong per litre, e.g. 23.2. Overrides the fetched price until cleared.")
        }
        .task {
            await store.loadSettings()
            await store.loadPrices()
            await store.loadPhones()
            load()
        }
        .onAppear { if !loaded { load() } }
        .onDisappear(perform: commit)
    }

    private func capacity(_ label: String, _ text: Binding<String>, unit: String, source: EnergySettings.Source, placeholder: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(source.label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.raisedBorder))
                .onSubmit(commit)
                .accessibilityLabel(label)
            Text(unit).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
        }
    }

    private var electricityHint: String {
        guard let hint = store.prices?.electricityHint, let tiers = hint.tiersVndPerKwh, let top = tiers.last, let bottom = tiers.first else {
            return "Your EVN tier or charger rate, incl. VAT"
        }
        var text = "EVN tiers \(Money.kdong(bottom))–\(Money.kdong(top, per: "kWh")) incl. VAT"
        if let from = hint.tariffFrom { text += " · tariff from \(TripDetail.cycleLabel(from))" }
        return text
    }

    private var petrolStale: Bool { store.prices?.petrol?.stale == true && draft.petrolOverrideVndPerLitre == nil }

    private var petrolHint: String {
        if draft.petrolOverrideVndPerLitre != nil { return "Your own price · tap to change or clear" }
        guard let petrol = store.prices?.petrol else { return "No price fetched yet · tap to set one" }
        var parts = [petrol.product ?? "E10 RON 95-III"]
        var when = petrol.source ?? "fetched"
        if let at = petrol.fetchedAt { when += ", " + at.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }
        parts.append(when)
        if petrol.stale == true { parts.append("may be out of date") }
        return parts.joined(separator: " · ")
    }

    private var otherPhones: String {
        let others = store.phones.filter { $0.id != PhoneIdentity.id }.map(\.name)
        return others.isEmpty ? "none yet" : others.joined(separator: ", ")
    }

    private func load() {
        loaded = true
        draft = store.settings
        phoneName = PhoneIdentity.name
        electricity = draft.priceKwh.map { ($0 / 1000).formatted(.number.precision(.fractionLength(1))) } ?? ""
        battery = draft.batteryKwh.formatted(.number.precision(.fractionLength(0...1)))
        tank = draft.tankLitres.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func commit() {
        var new = draft
        new.priceKwh = Self.number(electricity).map { $0 * 1000 }
        if let value = Self.number(battery), value > 0, value != new.batteryKwh {
            new.batteryKwh = value
            new.batterySource = .manual
        }
        if let value = Self.number(tank), value > 0, value != new.tankLitres {
            new.tankLitres = value
            new.tankSource = .manual
        }
        let name = phoneName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != PhoneIdentity.name { PhoneIdentity.name = name }
        draft = new
        guard new != store.settings else { return }
        Task { await store.update(new) }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }
}
