import SwiftUI

/// Small status pill: shows whether commands go straight to the car over Bluetooth.
struct BluetoothChip: View {
    let link: BleCarLink
    var importing = false
    let action: () -> Void

    private var color: Color {
        switch link.state {
        case .ready: Theme.accent
        case .failed, .bluetoothOff: Theme.warning
        default: Theme.muted
        }
    }

    private var busy: Bool {
        importing || [.searching, .connecting, .authenticating].contains(link.state)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini).tint(Theme.muted)
                } else {
                    Image(systemName: link.state == .ready ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(link.hasKey ? link.state.label : "Set up Bluetooth key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xC9D1D9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(RaisedButtonStyle(active: link.state == .ready, cornerRadius: 14))
        .accessibilityHint("Shows Bluetooth details")
    }
}

/// Details: state, recent events, and key management.
struct BluetoothSheet: View {
    let link: BleCarLink
    @Bindable var autoUnlock: AutoUnlock
    var importing: Bool
    let importKey: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingIntro = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status", value: link.hasKey ? link.state.label : "No key")
                    if link.hasKey {
                        if [.searching, .connecting, .authenticating].contains(link.state) {
                            Button("Stop looking for the car", action: link.stop)
                        } else {
                            Button("Reconnect") { link.disconnect(); link.connect() }
                        }
                        Button("Remove Bluetooth key", role: .destructive) { link.removeKey() }
                    } else {
                        Button(importing ? "Importing…" : "Import key from Mac server", action: importKey)
                            .disabled(importing)
                    }
                } footer: {
                    Text("With the key, lock, unlock, trunk and honk go straight to the car over Bluetooth when you're nearby. Everything else, and anything out of range, uses BYD's cloud.")
                }
                if link.hasKey { autoUnlockSection }
                Section("Recent events") {
                    if link.log.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    }
                    ForEach(Array(link.log.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 13, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Bluetooth key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showingIntro) {
            AutoUnlockIntro {
                showingIntro = false
                autoUnlock.enable()
            } cancel: {
                showingIntro = false
            }
        }
        .task {
            // Live signal strength while the sheet is open, to help pick a distance.
            while !Task.isCancelled {
                link.readRSSI()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var autoUnlockSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBorder))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock as I walk up")
                    Text(autoUnlockSubtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Unlock as I walk up", isOn: Binding(
                    get: { autoUnlock.isOn },
                    set: { on in
                        if !on {
                            autoUnlock.disable()
                        } else if autoUnlock.authorization == .authorizedAlways {
                            autoUnlock.enable()
                        } else {
                            showingIntro = true
                        }
                    }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }

            if autoUnlock.isOn {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Unlock distance")
                        Spacer()
                        Text("≈ \(autoUnlock.distance) m").fontWeight(.semibold).foregroundStyle(Theme.accent)
                    }
                    Picker("Unlock distance", selection: $autoUnlock.distance) {
                        ForEach(AutoUnlock.distances, id: \.self) { Text("\($0) m").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Approximate. Walls, pockets and bags weaken the signal, so start short and widen it if it unlocks too late.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let rssi = link.rssi {
                        Text("Signal now: \(rssi) dBm").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                HStack(spacing: 6) {
                    Text("Location access")
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    Text("Always").foregroundStyle(.secondary)
                }
            } else if autoUnlock.needsAlways {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Auto-unlock needs location set to Always, so the app can wake up near the car when it's closed.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .symbolRenderingMode(.multicolor)
                    Button("Open Settings", action: autoUnlock.openSettings)
                        .fontWeight(.semibold)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Auto-unlock")
        } footer: {
            Text("Unlocks only after you've been away from the car and come back, never while you're already nearby. Always over Bluetooth, never through BYD's cloud.")
        }
    }

    private var autoUnlockSubtitle: String {
        guard autoUnlock.isOn else { return "Off" }
        guard autoUnlock.carLocation != nil else { return "On · connect to the car once so it knows where it's parked" }
        return "On · within about \(autoUnlock.distance) m"
    }
}

/// Explains why auto-unlock needs Always location, before iOS asks.
struct AutoUnlockIntro: View {
    let proceed: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "lock.open")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent))
            VStack(alignment: .leading, spacing: 8) {
                Text("Unlock as you walk up").font(.system(size: 24, weight: .bold))
                (Text("To do this, the app needs your location set to ") + Text("Always").bold() + Text("."))
                    .foregroundStyle(Color(hex: 0xC9D1D9))
            }
            VStack(alignment: .leading, spacing: 14) {
                point("mappin.and.ellipse", "Wakes up near the car.", "iOS tells the app when you get close to where the car is parked, even if the app is closed.")
                point("wifi", "Unlocks only when you're close.", "Bluetooth checks you're within the distance you choose, after you've been away.")
                point("checkmark.shield", "Stays on your iPhone.", "Your location is never sent anywhere.")
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button(action: proceed) {
                    Text("Continue").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.background)
                Button("Not now", action: cancel)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(Color(hex: 0xC9D1D9))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .presentationDetents([.large])
        .presentationBackground(Color(hex: 0x161B20))
        .preferredColorScheme(.dark)
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            (Text(title).bold().foregroundColor(Theme.text) + Text(" " + detail).foregroundColor(Color(hex: 0xC9D1D9)))
                .font(.system(size: 15))
        }
    }
}
