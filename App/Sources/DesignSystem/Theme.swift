import SwiftUI

/// Smooooth Operator visual identity (spec §12: dark, premium, motorsport).
/// Every color, gradient and surface lives here — views never invent styles.
/// The signature is the "heat" gradient: blaze orange → amber, used for the
/// brand, CTAs, score rings and route traces. Green stays reserved for
/// verification semantics (verified/valid), never decoration.
enum SOTheme {
    // Ground & surfaces
    static let ground = Color(red: 0.039, green: 0.043, blue: 0.051)     // #0A0B0D
    static let surface = Color(red: 0.082, green: 0.090, blue: 0.110)    // #15171C
    static let elevated = Color(red: 0.114, green: 0.125, blue: 0.153)   // #1D2027
    static let hairline = Color.white.opacity(0.08)

    // Signature heat accent
    static let heatStart = Color(red: 1.0, green: 0.373, blue: 0.122)    // #FF5F1F
    static let heatEnd = Color(red: 1.0, green: 0.690, blue: 0.122)      // #FFB01F
    static var heat: LinearGradient {
        LinearGradient(
            colors: [heatStart, heatEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // Verdict semantics (spec §27) — never used decoratively.
    static let verified = Color(red: 0.204, green: 0.827, blue: 0.408)   // #34D368
    static let caution = Color(red: 1.0, green: 0.690, blue: 0.122)
    static let danger = Color(red: 1.0, green: 0.302, blue: 0.271)

    static let textSecondary = Color(red: 0.545, green: 0.576, blue: 0.631) // #8B93A1
}

/// Standard elevated card: surface fill, hairline stroke, 20pt radius.
struct SOCardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(SOTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(SOTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func soCard(padding: CGFloat = 16) -> some View {
        modifier(SOCardModifier(padding: padding))
    }
}

/// The primary CTA: heat capsule with a soft glow. Black label for maximum
/// contrast on the gradient.
struct HeatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.black))
            .tracking(1.2)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(SOTheme.heat, in: Capsule())
            .shadow(color: SOTheme.heatStart.opacity(0.45), radius: 16, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Secondary action: quiet outlined capsule.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(SOTheme.elevated, in: Capsule())
            .overlay(Capsule().strokeBorder(SOTheme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
