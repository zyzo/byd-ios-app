import SwiftUI

enum Theme {
    static let background = Color(hex: 0x0D1013)
    static let card = Color(hex: 0x12161A)
    static let cardBorder = Color(hex: 0x1E242B)
    static let raised = Color(hex: 0x222931)
    static let raisedBorder = Color(hex: 0x333C46)
    static let carBody = Color(hex: 0x1E242B)
    static let carGlass = Color(hex: 0x2B333C)
    static let carLine = Color(hex: 0x3A434D)
    static let fuel = Color(hex: 0x5B6672)
    static let text = Color(hex: 0xF2F4F6)
    static let muted = Color(hex: 0x9AA4AE)
    static let accent = Color(hex: 0x3DD6C4)
    static let warning = Color(hex: 0xF5A524)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Raised, key-like button: lighter surface, top highlight and a drop shadow.
/// Pressing sinks it; `active` makes it glow in `tint`.
struct RaisedButtonStyle: ButtonStyle {
    var active = false
    var tint = Theme.accent
    var cornerRadius: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        configuration.label
            .background(shape.fill(active ? tint.opacity(0.15) : Theme.raised))
            .overlay(shape.strokeBorder(active ? tint : Theme.raisedBorder, lineWidth: 1))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(pressed ? 0.03 : 0.09), .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: active ? tint.opacity(0.25) : .black.opacity(0.55), radius: pressed ? 1 : 10, y: pressed ? 1 : 8)
            .shadow(color: .black.opacity(0.4), radius: 2, y: pressed ? 0 : 2)
            .scaleEffect(pressed ? 0.985 : 1)
            .offset(y: pressed ? 2 : 0)
            .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

/// The Bluetooth rune, since SF Symbols has no Bluetooth glyph.
struct BluetoothRune: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        // Vertical stem.
        p.move(to: CGPoint(x: r.minX + w * 0.5, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + w * 0.5, y: r.maxY))
        // Upper triangle.
        p.move(to: CGPoint(x: r.minX, y: r.minY + h * 0.27))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.73))
        p.addLine(to: CGPoint(x: r.minX + w * 0.5, y: r.maxY))
        // Lower triangle.
        p.move(to: CGPoint(x: r.minX, y: r.minY + h * 0.73))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.27))
        p.addLine(to: CGPoint(x: r.minX + w * 0.5, y: r.minY))
        return p
    }
}
