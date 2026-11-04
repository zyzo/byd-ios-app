import SwiftUI
import WidgetKit

/// Full-width (medium) Home Screen widget: battery, range, lock state and four
/// buttons that send commands without opening the app.
struct CarWidget: Widget {
    static let kind = "CarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CarProvider()) { entry in
            CarWidgetView(entry: entry)
                .containerBackground(Theme.card, for: .widget)
        }
        .configurationDisplayName(AppConfig.displayName)
        .description("Battery, range and lock state, with lock, trunk, A/C and honk buttons.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct CarWidgetView: View {
    let entry: CarEntry

    var body: some View {
        if let status = entry.status {
            content(status)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppConfig.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(entry.offline ? "Can't reach the server. Open the app to check the connection." : "Open the app once to load your car.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private func content(_ s: CarStatus) -> some View {
        let locked = s.locked ?? false
        let lockKnown = s.locked != nil
        let percent = s.batteryPercent ?? 0

        return VStack(spacing: 0) {
            HStack {
                Text((s.model ?? AppConfig.displayName).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.muted)
                Spacer()
                pill
            }

            Spacer(minLength: 6)

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text("\(Int(percent.rounded()))")
                        .font(.system(size: 36, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(entry.offline ? Theme.muted : Theme.text)
                    Text("%")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(entry.offline ? Theme.fuel : Theme.muted)
                }
                (Text("\(Int((s.rangeTotalKm ?? 0).rounded()))")
                    .foregroundColor(entry.offline ? Theme.muted : Theme.text)
                    .fontWeight(.semibold)
                    + Text(" km").foregroundColor(entry.offline ? Theme.fuel : Theme.muted))
                    .font(.system(size: 15))
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.offline || !lockKnown ? Theme.fuel : (locked ? Theme.accent : Theme.warning))
                            .frame(width: 7, height: 7)
                        Text(lockKnown ? (locked ? "Locked" : "Unlocked") : "Lock unknown")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(entry.offline ? Theme.muted : Theme.text)
                    }
                    Text(detail(s))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            }

            Spacer(minLength: 8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule()
                        .fill(entry.offline ? Theme.fuel : Theme.accent)
                        .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                }
            }
            .frame(height: 4)

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                commandButton(locked ? "Locked" : "Lock",
                              systemImage: locked ? "lock.fill" : "lock.open.fill",
                              active: locked && lockKnown,
                              control: .lock,
                              command: locked ? .unlock : .lock)
                commandButton("Trunk",
                              systemImage: "car.side.rear.open",
                              active: s.trunkOpen ?? false,
                              control: .trunk,
                              command: s.trunkOpen ?? false ? .trunkClose : .trunkOpen)
                commandButton(s.acOn ?? false ? "A/C on" : "A/C",
                              systemImage: "snowflake",
                              active: s.acOn ?? false,
                              control: .ac,
                              command: s.acOn ?? false ? .acStop : .acStart)
                commandButton("Honk",
                              systemImage: "speaker.wave.3.fill",
                              active: false,
                              control: .honk,
                              command: .honk)
            }
            .disabled(entry.offline || entry.pending != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var pill: some View {
        if entry.offline {
            pillLabel("No internet", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
        } else if entry.status?.charging == true {
            pillLabel("Charging", systemImage: "bolt.fill", tint: Theme.accent)
        }
    }

    private func pillLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
    }

    private func detail(_ s: CarStatus) -> String {
        var parts: [String] = []
        if s.acOn == true { parts.append("A/C on") }
        if let at = s.updatedAt {
            if entry.offline {
                parts.append("Last update " + at.formatted(.relative(presentation: .numeric)))
            } else {
                parts.append(at.formatted(date: .omitted, time: .shortened))
            }
        } else if entry.offline {
            parts.append("Last update unknown")
        }
        return parts.joined(separator: " · ")
    }

    /// One key. While `entry.pending` is this control's command the key shows a filling ring;
    /// while another one is pending it is dimmed (the row above disables all of them).
    /// While the app is connected to the car over Bluetooth, keys the Bluetooth key can
    /// send carry a Bluetooth badge and open the app to send that way instead of the cloud.
    private func commandButton(_ title: String, systemImage: String, active: Bool, control: Control, command: CarCommand) -> some View {
        let loading = entry.pending?.control == control
        let othersBusy = entry.pending != nil && !loading
        let bluetooth = entry.bluetooth && command.worksOverBluetooth
        let label = Group {
            if loading {
                // Widgets are static snapshots: only a date-driven progress view moves.
                ProgressView(timerInterval: entry.pendingSince...entry.pendingSince.addingTimeInterval(12),
                             countsDown: false,
                             label: { EmptyView() },
                             currentValueLabel: { EmptyView() })
                    .progressViewStyle(.circular)
                    .tint(Theme.accent)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .overlay(alignment: .topTrailing) {
            if bluetooth && !loading {
                BluetoothRune()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 6, height: 10)
                    .padding(.top, 7)
                    .padding(.trailing, 8)
            }
        }
        return Group {
            if bluetooth {
                Button(intent: CarBluetoothCommandIntent(command)) { label }
            } else {
                Button(intent: CarCommandIntent(command)) { label }
            }
        }
        .buttonStyle(WidgetKeyStyle(active: active || loading, dimmed: othersBusy))
        .accessibilityLabel(loading ? "Sending" : title)
        .accessibilityHint(bluetooth ? "Opens the app and sends over Bluetooth" : "")
    }
}

/// Flat version of the app's raised key: widgets can't draw shadows outside their tiles.
private struct WidgetKeyStyle: ButtonStyle {
    var active: Bool
    var dimmed = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .foregroundStyle(active ? Theme.accent : Theme.text)
            .background(shape.fill(active ? Theme.accent.opacity(0.15) : Theme.raised))
            .overlay(shape.strokeBorder(active ? Theme.accent : Theme.raisedBorder, lineWidth: 1))
            .opacity(dimmed ? 0.4 : (configuration.isPressed ? 0.6 : 1))
    }
}

#Preview(as: .systemMedium) {
    CarWidget()
} timeline: {
    CarEntry(date: .now, status: .sample)
    CarEntry(date: .now, status: .sample, bluetooth: true)
    CarEntry(date: .now, status: {
        var s = CarStatus.sample
        s.locked = false
        s.acOn = true
        s.charging = true
        return s
    }())
    CarEntry(date: .now, status: .sample, offline: true)
    CarEntry(date: .now, status: .sample, pending: .unlock)
}
