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
    @State private var pendingChargeDelete: Charge?
    @State private var editingCharge: Charge?
    @State private var detent: PresentationDetent = .large

    private var weeks: [Week] { TripMath.weeks(store.trips) }
    private var weekTrips: [Trip] { TripMath.trips(store.trips, in: week) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TabView(selection: $week) {
                        ForEach(weeks) { w in
                            WeekCard(week: w, trips: TripMath.trips(store.trips, in: w), charges: TripMath.charges(store.charges, in: w),
                                     settings: store.settings, previous: previous, next: next)
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

                ForEach(TripMath.byDay(weekTrips, store.unattachedCharges(TripMath.charges(store.charges, in: week))), id: \.day) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            switch entry {
                            case .trip(let trip):
                                NavigationLink(value: trip.id) { TripRow(trip: trip, charge: store.charge(after: trip), settings: store.settings) }
                                    .listRowBackground(Theme.card)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { pendingDelete = trip } label: { Label("Delete", systemImage: "trash") }
                                    }
                            case .charge(let charge):
                                Button { editingCharge = charge } label: { ChargeRow(charge: charge, settings: store.settings) }
                                    .listRowBackground(Theme.card)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { pendingChargeDelete = charge } label: { Label("Delete", systemImage: "trash") }
                                    }
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
            .confirmationDialog("Not a charge?", isPresented: Binding(get: { pendingChargeDelete != nil }, set: { if !$0 { pendingChargeDelete = nil } }), titleVisibility: .visible) {
                Button("Delete charge", role: .destructive) {
                    if let charge = pendingChargeDelete { Task { await store.delete(charge) } }
                    pendingChargeDelete = nil
                }
            } message: {
                Text("The battery level rose while the car was parked. Delete it if the car wasn't charged.")
            }
            .sheet(item: $editingCharge) { charge in
                RefillEditor(refill: charge.refill(store.settings), remove: { Task { await store.delete(charge) } }) { amount, cost in
                    Task { await store.editCharge(charge, amount: amount, cost: cost) }
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
    let charges: [Charge]
    let settings: EnergySettings
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
                if let paid = chargesPaid {
                    Text("Charging \(Money.kdong(paid))")
                }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }

    /// What the week's charges between trips came to, kept apart from the trips' energy cost.
    private var chargesPaid: Double? {
        let costs = charges.compactMap { $0.refill(settings).cost }
        return costs.isEmpty ? nil : costs.reduce(0, +)
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
    var charge: Charge? = nil
    let settings: EnergySettings

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
            ForEach(trip.refills(settings), id: \.kind) { refill in
                RefillBadge(refill: refill)
            }
            if let charge {
                RefillBadge(refill: charge.refill(settings))
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
    @State private var editing: Refill?
    @State private var editingCharge: Charge?

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
                if !trip.tooShort, let cost = trip.cost {
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
        .sheet(item: $editing) { refill in
            RefillEditor(refill: refill) { amount, cost in
                Task { await store.editRefill(trip, refill.kind, amount: amount, cost: cost) }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingCharge) { charge in
            RefillEditor(refill: charge.refill(store.settings), remove: { Task { await store.delete(charge) } }) { amount, cost in
                Task { await store.editCharge(charge, amount: amount, cost: cost) }
            }
            .presentationDetents([.medium])
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
                if trip.tooShort {
                    // The car's gauges didn't move: zeros would read as a free trip.
                    tile("–", "kWh")
                    tile("–", "litres")
                    tile("–", "cost")
                } else {
                    tile(trip.kwh.formatted(.number.precision(.fractionLength(1))), "kWh")
                    tile(trip.litres.formatted(.number.precision(.fractionLength(1))), "litres")
                    if let cost = trip.cost {
                        tile(Money.kdong(cost.total), "cost · \(Money.kdong(cost.perKm, per: "km"))", unitStyled: true)
                    } else {
                        tile("–", "cost")
                    }
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
            if !badges.isEmpty || !refills.isEmpty || chargeAfter != nil {
                Divider().overlay(Theme.cardBorder)
                ForEach(refills, id: \.kind) { refill in
                    Button { editing = refill } label: { RefillBadge(refill: refill, editable: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edit what it came to")
                }
                if let charge = chargeAfter {
                    Button { editingCharge = charge } label: { RefillBadge(refill: charge.refill(store.settings), editable: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Edit what the charge came to")
                }
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

    private var refills: [Refill] { trip.refills(store.settings) }
    private var chargeAfter: Charge? { store.charge(after: trip) }

    private struct Badge {
        var text: String
        var symbol: String?
        var amber = false
    }

    private var badges: [Badge] {
        var list: [Badge] = []
        if trip.withoutPhone { list.append(Badge(text: "Without phone", symbol: "iphone.slash")) }
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
    @State private var efficiency = ""
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
                capacity("Charging efficiency", $efficiency, unit: "%", subtitle: "of the charger's kWh that reach the battery", placeholder: "90")
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
        capacity(label, text, unit: unit, subtitle: source.label, placeholder: placeholder)
    }

    private func capacity(_ label: String, _ text: Binding<String>, unit: String, subtitle: String, placeholder: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
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
        efficiency = (draft.chargeEfficiency * 100).formatted(.number.precision(.fractionLength(0)))
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
        if let value = Self.number(efficiency), (50...100).contains(value) {
            new.chargeEfficiency = value / 100
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

extension Refill: Identifiable {
    var id: Kind { kind }
}

/// A charge while the car stood between two trips: "Charged 09:53–10:24 · 26 → 70 %", then what
/// it came to. Tapping it opens the editor.
struct ChargeRow: View {
    let charge: Charge
    let settings: EnergySettings

    var body: some View {
        let refill = charge.refill(settings)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                Text("Charged").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("· \(charge.timeRange)").font(.system(size: 15)).foregroundStyle(Theme.muted)
                Spacer()
                Text("\(Int(charge.socStart)) → \(Int(charge.socEnd)) %")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).monospacedDigit()
            }
            HStack(spacing: 6) {
                if let summary = refill.summary {
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                }
                Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit what the charge came to")
    }
}

/// "⛽ Refuelled ≈ 33.6 L · ≈ 711kđ", amber like the car's other warnings about a trip.
struct RefillBadge: View {
    let refill: Refill
    var editable = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: refill.symbol).font(.system(size: 11)).foregroundStyle(Theme.warning)
            Text(refill.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hex: 0xC9D1D9))
            if let summary = refill.summary {
                Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            if editable {
                Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Theme.background))
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
        .accessibilityElement(children: .combine)
    }
}

/// What a refuel or a charge really came to: litres or kWh, and what was paid in kđ.
struct RefillEditor: View {
    let refill: Refill
    /// Offers "Not a charge" for a charge found between trips.
    var remove: (() -> Void)? = nil
    let save: (_ amount: Double?, _ cost: Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var paid = ""
    @State private var confirmingRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field(refill.kind == .fuel ? "Fuel added" : "Energy added", text: $amount, unit: refill.unit,
                          placeholder: refill.estimatedAmount.map(Self.format) ?? "")
                    field("Paid", text: $paid, unit: "kđ", placeholder: estimatedCost.map { Self.format($0 / 1000) } ?? "")
                } footer: {
                    Text(footer)
                }
                if !refill.amountEstimated || !refill.costEstimated {
                    Section {
                        Button("Use the estimate") {
                            save(nil, nil)
                            dismiss()
                        }
                    }
                }
                if let remove {
                    Section {
                        Button("Not a charge", role: .destructive) { confirmingRemove = true }
                    }
                }
            }
            .confirmationDialog("Not a charge?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Delete charge", role: .destructive) {
                    remove?()
                    dismiss()
                }
            } message: {
                Text("The battery level rose while the car was parked. Delete it if the car wasn't charged.")
            }
            .navigationTitle(refill.kind == .fuel ? "Refuel" : "Charge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(Self.number(amount), Self.number(paid).map { $0 * 1000 })
                        dismiss()
                    }
                }
            }
            .onAppear {
                if !refill.amountEstimated, let value = refill.amount { amount = Self.format(value) }
                if !refill.costEstimated, let value = refill.cost { paid = Self.format(value / 1000) }
            }
        }
    }

    /// What the cost would be from the litres or kWh typed, or the estimate.
    private var estimatedCost: Double? {
        guard let price = refill.price, let litres = Self.number(amount) ?? refill.estimatedAmount else { return nil }
        return litres * price
    }

    private var footer: String {
        if let note = refill.note { return note }
        let gauge = refill.kind == .fuel ? "fuel gauge" : "battery level"
        guard refill.estimatedAmount != nil else {
            return "The \(gauge) didn't rise over the whole trip, so there's no estimate: enter what was added."
        }
        var text = "Leave a field empty to use the estimate from how far the \(gauge) rose"
        if let price = refill.price {
            text += ", at \(Money.kdong(price, per: refill.unit))"
        }
        return text + ". The car reports whole percent, so it can be off by about 1 % of the \(refill.kind == .fuel ? "tank" : "battery")."
    }

    private func field(_ title: String, text: Binding<String>, unit: String, placeholder: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
            Text(unit).foregroundStyle(Theme.muted).fixedSize().frame(minWidth: 34, alignment: .leading)
        }
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    private static func number(_ text: String) -> Double? {
        let value = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        return value.flatMap { $0 > 0 ? $0 : nil }
    }
}
