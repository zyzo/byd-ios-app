import SwiftUI

/// Small pill: a Bluetooth icon, with a label only while the car is reachable over Bluetooth.
struct BluetoothChip: View {
    let link: BleCarLink
    var importing = false
    let action: () -> Void

    private var active: Bool { link.state == .ready }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                BluetoothRune()
                    .stroke(active ? Theme.accent : Theme.muted, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 13)
                if active {
                    Text("Bluetooth")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: 0xC9D1D9))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, active ? 10 : 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(RaisedButtonStyle(active: active, cornerRadius: 14))
        .accessibilityLabel("Bluetooth")
        .accessibilityValue(link.hasKey ? link.state.label : "Key not set up")
        .accessibilityHint("Shows Bluetooth details")
    }
}

/// Details: state, recent events, and key management.
struct BluetoothSheet: View {
    let link: BleCarLink
    @Bindable var autoUnlock: AutoUnlock
    @Bindable var autoLock: AutoLock
    var importing: Bool
    let importKey: () -> Void
    @Environment(\.dismiss) private var dismiss

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
                    Text("Lock, unlock, trunk and honk go over Bluetooth when nearby; everything else via BYD's cloud.")
                }
                if link.hasKey {
                    autoUnlockSection
                    autoLockSection
                }
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
                    set: { $0 ? autoUnlock.enable() : autoUnlock.disable() }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }

            if autoUnlock.isOn {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Unlock distance")
                        Spacer()
                        Text("≈ \(AutoUnlock.label(autoUnlock.distance))").fontWeight(.semibold).foregroundStyle(Theme.accent)
                    }
                    Picker("Unlock distance", selection: $autoUnlock.distance) {
                        ForEach(AutoUnlock.distances, id: \.self) { Text(AutoUnlock.label($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Approximate. Widen it if it unlocks too late.")
                        .font(.footnote).foregroundStyle(.secondary)
                    signalNow
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Auto-unlock")
        } footer: {
            Text("Only after the car has been out of Bluetooth range for \(Int(AutoUnlock.minAway / 60)) minutes. Bluetooth only, no location needed. Stops if you force-quit the app.")
        }
    }

    /// Live signal; in demo mode a long press steps it down.
    @ViewBuilder private var signalNow: some View {
        if let rssi = link.rssi {
            Text("Signal now: \(rssi) dBm")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .onLongPressGesture {
                    guard AppConfig.demo else { return }
                    link.demoSignal = link.demoSignal <= -88 ? -58 : link.demoSignal - 10
                }
        }
    }

    private var autoLockSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBorder))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock as I walk away")
                    Text(autoLock.isOn ? "On · beyond about \(AutoUnlock.label(autoLock.distance))" : "Off")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Lock as I walk away", isOn: Binding(
                    get: { autoLock.isOn },
                    set: { $0 ? autoLock.enable() : autoLock.disable() }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }

            if autoLock.isOn {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Lock distance")
                        Spacer()
                        Text("≈ \(AutoUnlock.label(autoLock.distance))").fontWeight(.semibold).foregroundStyle(Theme.accent)
                    }
                    Picker("Lock distance", selection: $autoLock.distance) {
                        ForEach(AutoUnlock.distances, id: \.self) { Text(AutoUnlock.label($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Approximate. Narrow it if it locks too late.")
                        .font(.footnote).foregroundStyle(.secondary)
                    signalNow
                    Text(autoLock.statusText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Auto-lock")
        } footer: {
            Text("A few seconds after you walk past the chosen distance. Bluetooth only; not while the car is on or a door is open.")
        }
    }

    private var autoUnlockSubtitle: String {
        guard autoUnlock.isOn else { return "Off" }
        return "On · within about \(AutoUnlock.label(autoUnlock.distance))"
    }
}
