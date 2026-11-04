import SwiftUI

struct HomeView: View {
    @State private var model = CarViewModel()
    @State private var showingBluetooth = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // Until the server answers, show the last known car (or a placeholder) dimmed and
                // untouchable; the chip under the range says it's being read.
                content(model.status ?? .sample)
                    .redacted(reason: model.status == nil ? .placeholder : [])
                    .disabled(model.stale)
                    .animation(.easeInOut(duration: 0.25), value: model.stale)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .refreshable { await model.load(refresh: true) }
        .task { await model.load() }
        .safeAreaInset(edge: .bottom) { errorBanner }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                model.ble.connect()
                model.runHandoff()
            }
        }
        .sheet(isPresented: $showingBluetooth) {
            BluetoothSheet(link: model.ble, autoUnlock: model.autoUnlock, importing: model.importingKey) {
                Task { await model.importBleKey() }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(carName)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.muted)
                Text(headline)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.text)
                BluetoothChip(link: model.ble, importing: model.importingKey) {
                    showingBluetooth = true
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func content(_ s: CarStatus) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battery").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    (Text("\(Int((s.batteryPercent ?? 0).rounded()))")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundColor(Theme.text)
                        + Text("%").font(.system(size: 28, weight: .bold)).foregroundColor(Theme.muted))
                }
                .opacity(dim)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total range").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    (Text("\(Int((s.rangeTotalKm ?? 0).rounded())) ")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Theme.text)
                        + Text("km").font(.system(size: 15)).foregroundColor(Theme.muted))
                }
                .opacity(dim)
                statusPill(s)
            }
            Spacer(minLength: 8)
            CarTopView(
                locked: s.locked,
                trunkOpen: s.trunkOpen ?? false,
                windowsOpen: s.windowsOpen ?? false,
                acOn: s.acOn ?? false
            )
            .opacity(dim)
        }

        Group {
            RangeBar(electricKm: s.rangeElectricKm ?? 0, fuelKm: s.rangeFuelKm ?? 0)

            LockButton(locked: s.locked ?? true, busy: model.pending.contains(.lock), action: model.toggleLock)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ControlTile(
                    title: "Trunk",
                    systemImage: "car.side.rear.open",
                    detail: s.trunkOpen == true ? "Open" : nil,
                    active: s.trunkOpen == true,
                    busy: model.pending.contains(.trunk),
                    action: model.toggleTrunk
                )
                ControlTile(
                    title: "Windows",
                    systemImage: "window.vertical.open",
                    detail: s.windowsOpen == true ? "Vent 10%" : nil,
                    active: s.windowsOpen == true,
                    busy: model.pending.contains(.windows),
                    action: model.toggleWindows
                )
                ControlTile(
                    title: "A/C",
                    systemImage: "snowflake",
                    detail: s.acOn == true ? "On · 21°" : nil,
                    active: s.acOn == true,
                    busy: model.pending.contains(.ac),
                    action: model.toggleAC
                )
                ControlTile(
                    title: "Honk",
                    systemImage: "speaker.wave.3.fill",
                    detail: model.pending.contains(.honk) ? "Horn & lights…" : nil,
                    active: model.pending.contains(.honk),
                    action: model.honk
                )
            }

            TyreCard(tyres: s.tyresBar, odometerKm: s.odometerKm)
        }
        .opacity(dim)
    }

    /// Last-known information is faded until the server confirms it.
    private var dim: Double { model.stale ? 0.45 : 1 }

    @ViewBuilder
    private func statusPill(_ s: CarStatus) -> some View {
        if model.isRefreshing && model.stale {
            chip {
                ProgressView().controlSize(.mini).tint(Theme.text)
                Text("Reading your car…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xC9D1D9))
            }
            .unredacted()
        } else {
            lockPill(s)
        }
    }

    private func lockPill(_ s: CarStatus) -> some View {
        var open: [String] = []
        if s.locked == false { open.append("Unlocked") }
        if s.trunkOpen == true { open.append("Trunk open") }
        if s.windowsOpen == true { open.append("Windows open") }
        let secure = open.isEmpty && s.locked == true
        let text = secure ? "Locked" : (open.isEmpty ? "Lock state unknown" : open.joined(separator: " · "))
        let time = s.updatedAt.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""

        return chip {
            Circle().fill(secure ? Theme.accent : Theme.warning).frame(width: 8, height: 8)
            Text(text + time)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xC9D1D9))
                .lineLimit(2)
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(message).font(.system(size: 14)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Button {
                    model.dismissError()
                    if model.stale { Task { await model.load() } }
                } label: {
                    Text(model.stale ? "Retry" : "OK").font(.system(size: 14, weight: .semibold))
                }
                .tint(Theme.accent)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.warning.opacity(0.6)))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: Text

    private var carName: String {
        let name = model.status?.model ?? "BYD"
        guard let plate = model.status?.plate, !plate.isEmpty else { return name.uppercased() }
        return "\(name.uppercased()) · \(plate)"
    }

    private var headline: String {
        guard let s = model.status, !model.stale else { return "Connecting…" }
        if s.acOn == true { return "A/C on" }
        if s.charging == true { return "Charging" }
        return "Parked"
    }
}
