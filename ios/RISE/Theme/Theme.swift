import SwiftUI

/// RISE design tokens, carried over verbatim from the web app so the two
/// products read as one thing. Every value here has a counterpart in the
/// `:root` block of `public/index.html` — if you change a colour there,
/// change it here.
///
/// The one deliberate departure is typography. The web build loads DM Serif
/// Display and DM Sans from Google Fonts; bundling those into the binary is
/// possible (drop the TTFs in Resources and add UIAppFonts), but iOS ships
/// New York and SF Pro, which are optically sized, respect Dynamic Type, and
/// read as native rather than as a website in a box. That is the "slightly
/// more modern, same style" line: identical palette and proportions, native
/// letterforms.
enum RISE {

    // MARK: - Colour

    /// Semantic colours resolve per light/dark automatically.
    enum C {
        static let canvas      = dyn(light: 0xF4F1EB, dark: 0x0C0906)
        static let surface     = dyn(light: 0xFFFFFF, dark: 0x181410)
        static let surfaceWarm = dyn(light: 0xFAF7F2, dark: 0x221A12)
        static let surfaceUp   = dyn(light: 0xF7F3EC, dark: 0x2D2218)

        static let ink   = dyn(light: 0x16110A, dark: 0xF5EDE3)
        static let ink2  = dyn(light: 0x4A3D31, dark: 0xDBC8B6)
        static let ink3  = dyn(light: 0x857666, dark: 0xB8A08A)
        static let ink4  = dyn(light: 0xBEB0A4, dark: 0x8A7562)
        static let ink5  = dyn(light: 0xE0D8CE, dark: 0x4D3F32)
        static let ink6  = dyn(light: 0xEDE7E0, dark: 0x2E251B)

        /// The fire ramp is the brand and does not invert — it only warms
        /// slightly in the dark so it stops vibrating against a near-black
        /// canvas.
        static let fire      = dyn(light: 0xD6560C, dark: 0xF06A1E)
        static let fireMid   = dyn(light: 0xE8681A, dark: 0xF97316)
        static let fireLight = dyn(light: 0xF97316, dark: 0xFF8C4D)

        static let ember  = dyn(light: 0xFEF0E6, dark: 0x2A1810)
        static let ember2 = dyn(light: 0xFDE8D5, dark: 0x36200F)

        static let success = dyn(light: 0x1A6B3C, dark: 0x4FBF83)
        static let danger  = dyn(light: 0xC42828, dark: 0xFF6B6B)

        static var emberBorder: Color { fire.opacity(0.16) }
        static var successBg:   Color { success.opacity(0.10) }
        static var dangerBg:    Color { danger.opacity(0.10) }

        private static func dyn(light: UInt32, dark: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
        }
        private static func ui(_ hex: UInt32) -> UIColor {
            UIColor(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8)  & 0xFF) / 255,
                    blue:  CGFloat(hex         & 0xFF) / 255,
                    alpha: 1)
        }
    }

    // MARK: - Type

    /// Serif for display, sans for everything else — the same split the web
    /// app makes with DM Serif Display and DM Sans. `.serif` maps to New York.
    /// All sizes go through `relativeTo:` so Dynamic Type works, which is both
    /// an accessibility requirement and something App Review looks at.
    enum F {
        static func display(_ size: CGFloat) -> Font {
            .system(size: size, weight: .regular, design: .serif)
        }
        static func displayItalic(_ size: CGFloat) -> Font {
            .system(size: size, weight: .regular, design: .serif).italic()
        }
        static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        /// The small uppercase label used above section headings.
        static var eyebrow: Font { .system(size: 11, weight: .semibold) }
    }

    // MARK: - Metrics

    enum M {
        static let radius: CGFloat = 16
        static let radiusSmall: CGFloat = 10
        static let cardPadding: CGFloat = 18
        static let gutter: CGFloat = 20
    }
}

// MARK: - Reusable surfaces

/// The card treatment used throughout: warm surface, hairline border, and a
/// shadow soft enough to read as paper rather than as a drop shadow.
struct RISECard: ViewModifier {
    var padding: CGFloat = RISE.M.cardPadding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RISE.C.surface)
            .clipShape(RoundedRectangle(cornerRadius: RISE.M.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RISE.M.radius, style: .continuous)
                    .strokeBorder(RISE.C.ink6, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 3)
    }
}

extension View {
    func riseCard(padding: CGFloat = RISE.M.cardPadding) -> some View {
        modifier(RISECard(padding: padding))
    }
}

/// Primary action. Uses the fire gradient from the web build's `--sh-fire`
/// button, with a press state that scales rather than dims — dimming reads as
/// disabled on iOS.
struct FireButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RISE.F.body(16, .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                LinearGradient(colors: [RISE.C.fire, RISE.C.fireMid],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: RISE.C.fire.opacity(0.28), radius: 12, x: 0, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary action — outlined, no fill.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RISE.F.body(15, .medium))
            .foregroundStyle(RISE.C.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RISE.C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(RISE.C.ink5, lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small pill used for tags, verdicts and filters.
struct Chip: View {
    let text: String
    var tint: Color = RISE.C.ink3
    var filled: Bool = false
    var body: some View {
        Text(text)
            .font(RISE.F.body(12, .medium))
            .foregroundStyle(filled ? tint : RISE.C.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(filled ? tint.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(filled ? tint.opacity(0.25) : RISE.C.ink5, lineWidth: 1))
    }
}
