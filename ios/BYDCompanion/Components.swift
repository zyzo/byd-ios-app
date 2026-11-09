import SwiftUI

struct ControlTile: View {
    let title: String
    let systemImage: String
    var detail: String?
    var active = false
    var busy = false
    var bluetooth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if busy {
                        ProgressView().tint(Theme.text)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(active ? Theme.accent : Theme.text)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .bluetoothBadge(bluetooth && !busy, inset: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RaisedButtonStyle(active: active))
        .disabled(busy)
        .accessibilityValue(detail ?? "")
        .accessibilityHint(bluetooth ? "Sends over Bluetooth" : "")
    }
}

struct LockButton: View {
    let locked: Bool
    var busy = false
    var bluetooth = false
    let action: () -> Void

    private var tint: Color { locked ? Theme.accent : Theme.warning }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.background)
                    if busy {
                        ProgressView().tint(Theme.text)
                    } else {
                        Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 44, height: 44)

                Text(locked ? "Locked" : "Unlocked")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .bluetoothBadge(bluetooth && !busy, inset: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(RaisedButtonStyle(active: !locked, tint: Theme.warning, cornerRadius: 24))
        .disabled(busy)
        .accessibilityLabel(locked ? "Car is locked. Unlock" : "Car is unlocked. Lock")
        .accessibilityHint(bluetooth ? "Sends over Bluetooth" : "")
    }
}

extension View {
    /// The widget keys' Bluetooth badge: marks a key that will send over the Bluetooth key.
    func bluetoothBadge(_ shown: Bool, inset: CGFloat) -> some View {
        overlay(alignment: .topTrailing) {
            if shown {
                BluetoothRune()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 7, height: 11)
                    .padding(.top, inset)
                    .padding(.trailing, inset + 2)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct RangeBar: View {
    let electricKm: Double
    let fuelKm: Double

    private var electricShare: Double {
        let total = electricKm + fuelKm
        return total > 0 ? min(max(electricKm / total, 0), 1) : 0
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.accent).frame(width: geo.size.width * electricShare)
                    Rectangle().fill(Theme.fuel)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            HStack {
                legend(icon: "bolt.fill", color: Theme.accent, label: "Electric", km: electricKm)
                Spacer()
                legend(icon: "fuelpump.fill", color: Theme.muted, label: "Fuel", km: fuelKm)
            }
            .font(.system(size: 13))
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(icon: String, color: Color, label: String, km: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            Text(label).foregroundStyle(Theme.muted)
            Text("\(Int(km.rounded())) km").fontWeight(.semibold).foregroundStyle(Theme.text)
        }
    }
}

struct TyreCard: View {
    let tyres: CarStatus.Tyres
    let odometerKm: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tyres (bar)").foregroundStyle(Theme.muted)
                Spacer()
                if let odometerKm {
                    Text("Odometer ").foregroundStyle(Theme.muted)
                        + Text("\(odometerKm.formatted(.number.precision(.fractionLength(0)))) km")
                        .fontWeight(.semibold).foregroundColor(Theme.text)
                }
            }
            .font(.system(size: 13))

            HStack {
                tyre("Front L", tyres.frontLeft)
                tyre("Front R", tyres.frontRight)
                tyre("Rear L", tyres.rearLeft)
                tyre("Rear R", tyres.rearRight)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private func tyre(_ label: String, _ bar: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(bar.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "–")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Top-down drawing of the car that reflects locks, trunk, windows and A/C.
/// Drawn in a 150×280 coordinate space and scaled to fit.
struct CarTopView: View {
    var locked: Bool?
    var trunkOpen: Bool
    var windowsOpen: Bool
    var acOn: Bool

    private var lockColor: Color { locked == false ? Theme.warning : Theme.accent }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 150
            ZStack {
                Canvas { ctx, _ in
                    ctx.scaleBy(x: s, y: s)
                    draw(in: &ctx)
                }
                ZStack {
                    Circle().fill(Theme.background)
                    Circle().stroke(lockColor, lineWidth: 2)
                    Image(systemName: locked == false ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(lockColor)
                }
                .frame(width: 40 * s, height: 40 * s)
                .position(x: 75 * s, y: 172 * s)
            }
        }
        .frame(width: 118, height: 220)
        .animation(.easeInOut(duration: 0.25), value: [trunkOpen, windowsOpen, acOn, locked ?? true])
        .accessibilityElement()
        .accessibilityLabel(
            "Car seen from above: \(locked == false ? "unlocked" : "locked"), trunk \(trunkOpen ? "open" : "closed"), windows \(windowsOpen ? "open" : "closed"), A/C \(acOn ? "on" : "off")"
        )
    }

    private func draw(in ctx: inout GraphicsContext) {
        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        }
        /// A panel bounded by two curved edges: top from x1 to x2, bottom from bx2 back to bx1.
        /// Each edge is (y, control y) with the control point at the centre line.
        func panel(top: (CGFloat, CGFloat), bottom: (CGFloat, CGFloat), x1: CGFloat, x2: CGFloat, bx1: CGFloat, bx2: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: x1, y: top.0))
            p.addQuadCurve(to: CGPoint(x: x2, y: top.0), control: CGPoint(x: 75, y: top.1))
            p.addLine(to: CGPoint(x: bx2, y: bottom.0))
            p.addQuadCurve(to: CGPoint(x: bx1, y: bottom.0), control: CGPoint(x: 75, y: bottom.1))
            p.closeSubpath()
            return p
        }

        let windowFill = windowsOpen ? Theme.accent : Theme.carGlass

        ctx.fill(rounded(3, 88, 14, 9, 4), with: .color(Theme.carLine))
        ctx.fill(rounded(133, 88, 14, 9, 4), with: .color(Theme.carLine))

        let body = rounded(15, 10, 120, 260, 50)
        ctx.fill(body, with: .color(Theme.carBody))
        ctx.stroke(body, with: .color(Theme.carLine), lineWidth: 2)

        var hood = Path()
        hood.move(to: CGPoint(x: 32, y: 40))
        hood.addQuadCurve(to: CGPoint(x: 118, y: 40), control: CGPoint(x: 75, y: 24))
        ctx.stroke(hood, with: .color(Theme.carLine), lineWidth: 2)

        // Windshield, roof, side windows, rear window.
        ctx.fill(panel(top: (80, 64), bottom: (114, 106), x1: 30, x2: 120, bx1: 38, bx2: 112), with: .color(Theme.carGlass))
        ctx.fill(rounded(38, 118, 74, 86, 12), with: .color(Theme.card))
        ctx.fill(rounded(25, 120, 8, 82, 4), with: .color(windowFill))
        ctx.fill(rounded(117, 120, 8, 82, 4), with: .color(windowFill))
        ctx.fill(panel(top: (208, 214), bottom: (230, 240), x1: 38, x2: 112, bx1: 32, bx2: 118), with: .color(Theme.carGlass))

        // Trunk lid.
        let trunk = panel(top: (238, 250), bottom: (256, 270), x1: 30, x2: 120, bx1: 33, bx2: 117)
        ctx.fill(trunk, with: .color(trunkOpen ? Theme.accent.opacity(0.2) : Theme.carGlass))
        ctx.stroke(trunk, with: .color(trunkOpen ? Theme.accent : Theme.carGlass), lineWidth: 2)

        // A/C airflow.
        if acOn {
            for y in [132.0, 142.0] {
                var wave = Path()
                wave.move(to: CGPoint(x: 58, y: y))
                wave.addQuadCurve(to: CGPoint(x: 75, y: y), control: CGPoint(x: 66, y: y - 6))
                wave.addQuadCurve(to: CGPoint(x: 92, y: y), control: CGPoint(x: 84, y: y + 6))
                ctx.stroke(wave, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }
}
